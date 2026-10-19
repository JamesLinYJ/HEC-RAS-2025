import RASWorkspaceCore
import SwiftUI

struct StreamModeView: View {
    @ObservedObject var session: StreamModeSession
    @State private var pipeName: String
    @State private var hiddenObjectIDs = Set<String>()
    @State private var selectedObjectID: String?
    @State private var activeTinProfileID: String?
    @State private var lastSessionOperationID: UUID?
    @State private var selectedSample: StreamModeMapSample?
    @State private var cameraScale: CGFloat = 1
    @State private var cameraOffset: CGSize = .zero
    @State private var paintsZSurface = false

    init(session: StreamModeSession, initialPipeName: String = "") {
        self.session = session
        _pipeName = State(initialValue: initialPipeName)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Stream Mode")
                        .font(.title2.weight(.semibold))
                    Text("Receive source map objects from a named pipe.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Named pipe", text: $pipeName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .disabled(session.isActive)
                if session.isActive {
                    Button("Stop Stream", action: session.cancel)
                        .buttonStyle(.bordered)
                } else {
                    Button("Connect") { session.start(pipeName: pipeName) }
                        .buttonStyle(.borderedProminent)
                        .disabled(pipeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)

            Divider()

            HStack(spacing: 10) {
                statusIndicator
                Text(statusDescription)
                    .font(.callout)
                    .foregroundStyle(session.state.isFailure ? .red : .secondary)
                Spacer()
                if let selectedSample {
                    Text(selectedSample.summary)
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .help(selectedSample.summary)
                } else {
                    Text(L10n.text("Select a map feature to read values"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(String(format: L10n.text("%lld map objects"), Int64(session.mapObjects.count)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            HStack(spacing: 0) {
                StreamModeMapCanvas(objects: session.mapObjects,
                    hiddenObjectIDs: $hiddenObjectIDs,
                    selectedObjectID: $selectedObjectID,
                    activeTinProfileID: effectiveActiveTinProfileID,
                    selectedSample: $selectedSample,
                    cameraScale: $cameraScale,
                    cameraOffset: $cameraOffset,
                    paintsZSurface: $paintsZSurface)
                    .padding(12)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(session.mapObjects.reversed()) { object in
                            StreamModeObjectRow(object: object,
                                tinProfileIndex: tinProfileIndex(for: object),
                                isVisible: visibilityBinding(for: object),
                                isSelected: selectedObjectID == object.id || effectiveActiveTinProfileID == object.id) {
                                    selectedObjectID = object.id
                                    selectedSample = nil
                                    if object.source.objectType == "Tin" {
                                        activeTinProfileID = object.id
                                    }
                                }
                        }
                    }
                    .padding(12)
                }
                .frame(width: 260)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .onDisappear {
            if session.isActive { session.cancel() }
        }
        .onChange(of: session.currentOperationID) { _, operationID in
            guard let operationID, operationID != lastSessionOperationID else { return }
            lastSessionOperationID = operationID
            hiddenObjectIDs = []
            selectedObjectID = nil
            activeTinProfileID = nil
            selectedSample = nil
            cameraScale = 1
            cameraOffset = .zero
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch session.state {
        case .connecting:
            ProgressView().controlSize(.small)
        case .streaming:
            Circle().fill(.green).frame(width: 9, height: 9)
        case .failed:
            Circle().fill(.red).frame(width: 9, height: 9)
        default:
            Circle().fill(.secondary.opacity(0.45)).frame(width: 9, height: 9)
        }
    }

    private var statusDescription: String {
        switch session.state {
        case .idle: L10n.text("Ready to connect")
        case .connecting: L10n.text("Connecting to named pipe…")
        case .streaming: L10n.text("Receiving source map objects")
        case .completed(let count): String(format: L10n.text("Stream ended after %lld objects"), count)
        case .cancelled: L10n.text("Stream cancelled")
        case .failed(let message): message
        }
    }

    private func visibilityBinding(for object: StreamModeMapObject) -> Binding<Bool> {
        Binding(
            get: { !hiddenObjectIDs.contains(object.id) },
            set: { isVisible in
                if isVisible {
                    hiddenObjectIDs.remove(object.id)
                    if object.source.objectType == "Tin" {
                        activeTinProfileID = object.id
                        selectedObjectID = object.id
                    }
                } else {
                    hiddenObjectIDs.insert(object.id)
                }
            })
    }

    private var effectiveActiveTinProfileID: String? {
        if let activeTinProfileID,
           session.mapObjects.contains(where: { $0.id == activeTinProfileID && $0.source.objectType == "Tin" }) {
            return activeTinProfileID
        }
        return session.mapObjects.first(where: { $0.source.objectType == "Tin" })?.id
    }

    private func tinProfileIndex(for object: StreamModeMapObject) -> Int? {
        guard object.source.objectType == "Tin" else { return nil }
        return session.mapObjects.prefix(while: { $0.id != object.id })
            .filter { $0.source.objectType == "Tin" }.count
    }
}

private struct StreamModeObjectRow: View {
    let object: StreamModeMapObject
    let tinProfileIndex: Int?
    @Binding var isVisible: Bool
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: symbolName)
                        .foregroundStyle(objectColor)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(String(format: L10n.text("%lld coordinates · #%lld"),
                            Int64(object.source.coordinateCount), object.source.sequence + 1))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if let measureDescription {
                            Text(measureDescription)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)

            Toggle(L10n.text("Show streamed map object"), isOn: $isVisible)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help(L10n.text(isVisible ? "Hide streamed map object" : "Show streamed map object"))
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.13) : Color.secondary.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1)
        }
    }

    private var title: String {
        guard let tinProfileIndex else { return localizedObjectType }
        return String(format: L10n.text("TIN profile %lld"), Int64(tinProfileIndex))
    }

    private var localizedObjectType: String {
        switch object.source.objectType {
        case "Polygon": L10n.text("Polygon")
        case "Polyline": L10n.text("Polyline")
        case "Topology": L10n.text("Topology")
        case "Tin": L10n.text("Tin")
        case "Segment": L10n.text("Segment")
        default: L10n.text("Unknown streamed object")
        }
    }

    private var measureDescription: String? {
        let coordinates = object.source.coordinates
        var values: [String] = []
        if object.source.hasZ {
            let z = coordinates.compactMap(\.z).filter(\.isFinite)
            if let minimum = z.min(), let maximum = z.max() {
                values.append(String(format: L10n.text("Z range %@ to %@"),
                    Self.number(minimum), Self.number(maximum)))
            } else {
                values.append(L10n.text("Z values unavailable"))
            }
            values.append(String(format: L10n.text("Z fill %@"),
                object.source.zFillValue.map(Self.number) ?? L10n.text("No data")))
        }
        if object.source.hasM {
            let m = coordinates.compactMap(\.m).filter(\.isFinite)
            if let minimum = m.min(), let maximum = m.max() {
                values.append(String(format: L10n.text("M range %@ to %@"),
                    Self.number(minimum), Self.number(maximum)))
            } else {
                values.append(L10n.text("M values unavailable"))
            }
            values.append(String(format: L10n.text("M fill %@"),
                object.source.mFillValue.map(Self.number) ?? L10n.text("No data")))
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private static func number(_ value: Double) -> String { String(format: "%.3f", value) }

    private var symbolName: String {
        switch object.source.objectType {
        case "Polygon": "pentagon"
        case "Polyline", "Segment", "Topology": "point.topleft.down.curvedto.point.bottomright.up"
        case "Tin": "triangle"
        default: "map"
        }
    }

    private var objectColor: Color { streamObjectColor(object.source.objectType) }
}

private struct StreamModeMapCanvas: View {
    let objects: [StreamModeMapObject]
    @Binding var hiddenObjectIDs: Set<String>
    @Binding var selectedObjectID: String?
    let activeTinProfileID: String?
    @Binding var selectedSample: StreamModeMapSample?
    @Binding var cameraScale: CGFloat
    @Binding var cameraOffset: CGSize
    @Binding var paintsZSurface: Bool
    @State private var dragOriginOffset: CGSize?

    private var visibleObjects: [StreamModeMapObject] {
        objects.filter { object in
            guard !hiddenObjectIDs.contains(object.id) else { return false }
            return object.source.objectType != "Tin" || object.id == activeTinProfileID
        }
    }

    private var mapPoints: [MapPoint] {
        objects.flatMap(\.source.coordinates).map { MapPoint(x: $0.x, y: $0.y) }
    }

    private var containsTinWithZ: Bool {
        visibleObjects.contains { $0.source.objectType == "Tin" && $0.source.hasZ }
    }

    var body: some View {
        GeometryReader { proxy in
            let transform = MapTransform(points: mapPoints, size: proxy.size,
                scale: cameraScale, offset: cameraOffset)
            ZStack(alignment: .top) {
                Canvas { context, _ in
                    draw(visibleObjects, in: &context, transform: transform,
                        selectedObjectID: selectedObjectID, paintsZSurface: paintsZSurface)
                }

                MapPointerInteraction { location, delta in
                    guard let camera = MapPointerCamera.wheelZoom(scale: cameraScale,
                        offset: cameraOffset, canvasSize: proxy.size,
                        pointer: location, delta: delta) else { return }
                    cameraScale = camera.scale
                    cameraOffset = camera.offset
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)

                if visibleObjects.isEmpty {
                    ContentUnavailableView(L10n.text(objects.isEmpty
                        ? "No streamed map objects" : "All streamed objects are hidden"),
                        systemImage: objects.isEmpty
                            ? "point.3.connected.trianglepath.dotted" : "eye.slash")
                        .allowsHitTesting(false)
                }

                mapToolbar(size: proxy.size)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                    .padding(7)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if dragOriginOffset == nil { dragOriginOffset = cameraOffset }
                    guard let origin = dragOriginOffset,
                          let moved = MapPointerCamera.pan(offset: origin, by: value.translation) else { return }
                    cameraOffset = moved
                }
                .onEnded { _ in dragOriginOffset = nil })
            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                selectFeature(at: value.location, transform: transform)
            })
        }
    }

    @ViewBuilder
    private func mapToolbar(size: CGSize) -> some View {
        HStack(spacing: 8) {
            Button {
                zoom(by: 1.25, size: size)
            } label: {
                Label(L10n.text("Zoom In"), systemImage: "plus.magnifyingglass").labelStyle(.iconOnly)
            }
            .help(L10n.text("Zoom In"))

            Button {
                zoom(by: 0.8, size: size)
            } label: {
                Label(L10n.text("Zoom Out"), systemImage: "minus.magnifyingglass").labelStyle(.iconOnly)
            }
            .help(L10n.text("Zoom Out"))

            Button {
                cameraScale = 1
                cameraOffset = .zero
            } label: {
                Label(L10n.text("Fit Map"), systemImage: "arrow.up.left.and.arrow.down.right").labelStyle(.iconOnly)
            }
            .help(L10n.text("Fit Map"))

            Text("\(Int((cameraScale * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Toggle(L10n.text("Paint Z Surface"), isOn: $paintsZSurface)
                .toggleStyle(.checkbox)
                .disabled(!containsTinWithZ)
                .help(L10n.text("Color TIN triangles using the source Z samples"))
            if paintsZSurface, let range = activeTinZRange {
                Text(Self.formatted(range.lowerBound))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                LinearGradient(colors: [.white, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 64, height: 8)
                    .clipShape(Capsule())
                    .accessibilityLabel(L10n.text("Source Z surface color scale"))
                Text(Self.formatted(range.upperBound))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private var activeTinZRange: ClosedRange<Double>? {
        guard let object = visibleObjects.first(where: { $0.id == activeTinProfileID && $0.source.hasZ }) else { return nil }
        let values = object.source.coordinates.compactMap(\.z).filter(\.isFinite)
        guard let minimum = values.min(), let maximum = values.max() else { return nil }
        return minimum...maximum
    }

    private static func formatted(_ value: Double) -> String { String(format: "%.3f", value) }

    private func zoom(by factor: CGFloat, size: CGSize) {
        guard let update = MapPointerCamera.zoom(scale: cameraScale, offset: cameraOffset,
            canvasSize: size, pointer: CGPoint(x: size.width / 2, y: size.height / 2), by: factor) else { return }
        cameraScale = update.scale
        cameraOffset = update.offset
    }

    private func draw(_ objects: [StreamModeMapObject], in context: inout GraphicsContext,
                      transform: MapTransform, selectedObjectID: String?, paintsZSurface: Bool) {
        guard transform.size.width > 0, transform.size.height > 0 else { return }
        for object in objects {
            let frame = object.source
            let color = streamObjectColor(frame.objectType)
            let selected = object.id == selectedObjectID

            if frame.objectType == "Tin" {
                drawTin(object, in: &context, transform: transform,
                    selected: selected, paintsZSurface: paintsZSurface)
                continue
            }

            let path = combinedPath(frame, transform: transform)
            if frame.isClosed {
                context.fill(path, with: .color(color.opacity(selected ? 0.23 : 0.12)),
                    style: FillStyle(eoFill: true))
            }
            context.stroke(path, with: .color(selected ? .accentColor : color),
                lineWidth: selected ? 2.7 : 1.5)
        }
    }

    private func drawTin(_ object: StreamModeMapObject, in context: inout GraphicsContext,
                        transform: MapTransform, selected: Bool, paintsZSurface: Bool) {
        let frame = object.source
        let tinColor = streamObjectColor("Tin")
        let zValues = frame.coordinates.compactMap(\.z).filter(\.isFinite)
        let minimumZ = zValues.min()
        let maximumZ = zValues.max()

        for triangle in frame.triangles where triangle.count == 3 {
            guard triangle.allSatisfy({ frame.coordinates.indices.contains($0) }) else { continue }
            let vertices = triangle.map { frame.coordinates[$0] }
            var path = Path()
            path.move(to: transform.screen(MapPoint(x: vertices[0].x, y: vertices[0].y)))
            path.addLine(to: transform.screen(MapPoint(x: vertices[1].x, y: vertices[1].y)))
            path.addLine(to: transform.screen(MapPoint(x: vertices[2].x, y: vertices[2].y)))
            path.closeSubpath()

            if paintsZSurface, frame.hasZ,
               let minimumZ, let maximumZ,
               let values = vertices.map(\.z).asFiniteTriple {
                let sample = (values.0 + values.1 + values.2) / 3
                let band = zBand(for: sample, minimum: minimumZ, maximum: maximumZ)
                context.fill(path, with: .color(grayscaleColor(band).opacity(0.82)))
            } else if !paintsZSurface {
                context.fill(path, with: .color(tinColor.opacity(selected ? 0.18 : 0.06)))
            }
            context.stroke(path, with: .color(selected ? .accentColor : tinColor.opacity(0.82)),
                lineWidth: selected ? 2.3 : 0.85)
        }

        if frame.coordinates.count <= 250_000 {
            for coordinate in frame.coordinates {
                let center = transform.screen(MapPoint(x: coordinate.x, y: coordinate.y))
                let diameter: CGFloat = selected ? 4 : 2.6
                let marker = Path(ellipseIn: CGRect(x: center.x - diameter / 2,
                    y: center.y - diameter / 2, width: diameter, height: diameter))
                context.fill(marker, with: .color(selected ? .accentColor : tinColor))
            }
        }
    }

    private func combinedPath(_ frame: BackendStreamModeFrame, transform: MapTransform) -> Path {
        var path = Path()
        for indices in frame.paths where !indices.isEmpty {
            guard indices.allSatisfy({ frame.coordinates.indices.contains($0) }),
                  let first = indices.first else { continue }
            let point = frame.coordinates[first]
            path.move(to: transform.screen(MapPoint(x: point.x, y: point.y)))
            for index in indices.dropFirst() {
                let coordinate = frame.coordinates[index]
                path.addLine(to: transform.screen(MapPoint(x: coordinate.x, y: coordinate.y)))
            }
            if frame.isClosed { path.closeSubpath() }
        }
        return path
    }

    private func selectFeature(at location: CGPoint, transform: MapTransform) {
        let worldPoint = transform.world(location)
        for object in visibleObjects.reversed() {
            guard let sample = hitTest(object, at: location, worldPoint: worldPoint, transform: transform) else { continue }
            selectedObjectID = object.id
            selectedSample = sample
            return
        }
        selectedObjectID = nil
        selectedSample = nil
    }

    private func hitTest(_ object: StreamModeMapObject, at location: CGPoint,
                         worldPoint: MapPoint, transform: MapTransform) -> StreamModeMapSample? {
        let frame = object.source
        let x = worldPoint.x
        let y = worldPoint.y
        if frame.objectType == "Tin" {
            for triangle in frame.triangles.reversed() where triangle.count == 3 {
                guard triangle.allSatisfy({ frame.coordinates.indices.contains($0) }),
                      let weights = barycentricWeights(worldPoint, triangle: triangle, coordinates: frame.coordinates) else { continue }
                let vertices = triangle.map { frame.coordinates[$0] }
                let z = frame.hasZ ? interpolate(vertices.map(\.z), weights: weights) : nil
                let m = frame.hasM ? interpolate(vertices.map(\.m), weights: weights) : nil
                return StreamModeMapSample(objectID: object.id, x: x, y: y, z: z, m: m,
                    hasZ: frame.hasZ, hasM: frame.hasM)
            }
            for triangle in frame.triangles.reversed() where triangle.count == 3 {
                guard triangle.allSatisfy({ frame.coordinates.indices.contains($0) }) else { continue }
                let points = triangle.map { index in
                    let coordinate = frame.coordinates[index]
                    return transform.screen(MapPoint(x: coordinate.x, y: coordinate.y))
                }
                if pathDistance(location, points: points + [points[0]]) <= 5 {
                    return StreamModeMapSample(objectID: object.id, x: x, y: y, z: nil, m: nil,
                        hasZ: frame.hasZ, hasM: frame.hasM)
                }
            }
            return nil
        }

        let path = combinedPath(frame, transform: transform)
        if frame.isClosed && path.contains(location, eoFill: true) {
            return StreamModeMapSample(objectID: object.id, x: x, y: y, z: nil, m: nil,
                hasZ: false, hasM: false)
        }
        for sourceIndices in frame.paths where sourceIndices.count >= 2 {
            var indices = sourceIndices
            if frame.isClosed, indices.first != indices.last, let first = indices.first {
                indices.append(first)
            }
            let points = indices.compactMap { index -> CGPoint? in
                guard frame.coordinates.indices.contains(index) else { return nil }
                let coordinate = frame.coordinates[index]
                return transform.screen(MapPoint(x: coordinate.x, y: coordinate.y))
            }
            if pathDistance(location, points: points) <= 6 {
                let measures = nearestPathMeasures(location, indices: indices,
                    coordinates: frame.coordinates, transform: transform)
                return StreamModeMapSample(objectID: object.id, x: x, y: y,
                    z: frame.hasZ ? measures.z : nil, m: frame.hasM ? measures.m : nil,
                    hasZ: frame.hasZ, hasM: frame.hasM)
            }
        }
        return nil
    }

    private func barycentricWeights(_ point: MapPoint, triangle: [Int],
                                   coordinates: [BackendStreamModeCoordinate]) -> (Double, Double, Double)? {
        let p0 = coordinates[triangle[0]], p1 = coordinates[triangle[1]], p2 = coordinates[triangle[2]]
        let denominator = (p1.y - p2.y) * (p0.x - p2.x) + (p2.x - p1.x) * (p0.y - p2.y)
        guard denominator.isFinite, abs(denominator) > 1e-24 else { return nil }
        let a = ((p1.y - p2.y) * (point.x - p2.x) + (p2.x - p1.x) * (point.y - p2.y)) / denominator
        let b = ((p2.y - p0.y) * (point.x - p2.x) + (p0.x - p2.x) * (point.y - p2.y)) / denominator
        let c = 1 - a - b
        let tolerance = 1e-9
        guard [a, b, c].allSatisfy({ $0.isFinite && $0 >= -tolerance && $0 <= 1 + tolerance }) else { return nil }
        return (a, b, c)
    }

    private func interpolate(_ values: [Double?], weights: (Double, Double, Double)) -> Double? {
        guard values.count == 3, let v0 = values[0], let v1 = values[1], let v2 = values[2],
              v0.isFinite, v1.isFinite, v2.isFinite else { return nil }
        let value = v0 * weights.0 + v1 * weights.1 + v2 * weights.2
        return value.isFinite ? value : nil
    }

    private func nearestPathMeasures(_ location: CGPoint, indices: [Int],
                                     coordinates: [BackendStreamModeCoordinate],
                                     transform: MapTransform) -> (z: Double?, m: Double?) {
        guard indices.count >= 2 else { return (nil, nil) }
        var bestDistance = CGFloat.infinity
        var bestValues: (z: Double?, m: Double?) = (nil, nil)
        for index in 1..<indices.count {
            let firstIndex = indices[index - 1]
            let secondIndex = indices[index]
            guard coordinates.indices.contains(firstIndex), coordinates.indices.contains(secondIndex) else { continue }
            let first = coordinates[firstIndex]
            let second = coordinates[secondIndex]
            let a = transform.screen(MapPoint(x: first.x, y: first.y))
            let b = transform.screen(MapPoint(x: second.x, y: second.y))
            let dx = b.x - a.x
            let dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let fraction: CGFloat
            if lengthSquared > 0 {
                fraction = min(max(((location.x - a.x) * dx + (location.y - a.y) * dy) / lengthSquared, 0), 1)
            } else {
                fraction = 0
            }
            let distance = hypot(location.x - (a.x + fraction * dx), location.y - (a.y + fraction * dy))
            guard distance < bestDistance else { continue }
            bestDistance = distance
            bestValues = (interpolate(first.z, second.z, fraction: fraction),
                interpolate(first.m, second.m, fraction: fraction))
        }
        return bestValues
    }

    private func interpolate(_ first: Double?, _ second: Double?, fraction: CGFloat) -> Double? {
        guard let first, let second, first.isFinite, second.isFinite else { return nil }
        let value = first + (second - first) * Double(fraction)
        return value.isFinite ? value : nil
    }

    private func pathDistance(_ point: CGPoint, points: [CGPoint]) -> CGFloat {
        guard points.count >= 2 else { return .infinity }
        var minimum = CGFloat.infinity
        for index in 1..<points.count {
            minimum = min(minimum, distance(point, toSegmentFrom: points[index - 1], to: points[index]))
        }
        return minimum
    }

    private func distance(_ point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let projection = min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (start.x + projection * dx), point.y - (start.y + projection * dy))
    }

    private func zBand(for value: Double, minimum: Double, maximum: Double) -> Double {
        guard maximum > minimum else { return 0.5 }
        let normalized = min(max((value - minimum) / (maximum - minimum), 0), 1)
        return floor(normalized * 15) / 15
    }

    private func grayscaleColor(_ fraction: Double) -> Color {
        let channel = 1 - min(max(fraction, 0), 1)
        return Color(.sRGB, red: channel, green: channel, blue: channel, opacity: 1)
    }
}

private struct StreamModeMapSample: Equatable {
    let objectID: String
    let x: Double
    let y: Double
    let z: Double?
    let m: Double?
    let hasZ: Bool
    let hasM: Bool

    @MainActor var summary: String {
        var values = [String(format: L10n.text("X %@ · Y %@"), Self.number(x), Self.number(y))]
        if hasZ { values.append(z.map { String(format: L10n.text("Z %@"), Self.number($0)) } ?? L10n.text("Z no data")) }
        if hasM { values.append(m.map { String(format: L10n.text("M %@"), Self.number($0)) } ?? L10n.text("M no data")) }
        return values.joined(separator: " · ")
    }

    private static func number(_ value: Double) -> String { String(format: "%.3f", value) }
}

private extension Array where Element == Double? {
    var asFiniteTriple: (Double, Double, Double)? {
        guard count == 3, let first = self[0], let second = self[1], let third = self[2],
              first.isFinite, second.isFinite, third.isFinite else { return nil }
        return (first, second, third)
    }
}

private extension StreamModeSessionState {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

private func streamObjectColor(_ objectType: String) -> Color {
    switch objectType {
    case "Polygon": .orange
    case "Tin": .cyan
    default: .blue
    }
}
