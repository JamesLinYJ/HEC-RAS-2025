import Foundation
import RASWorkspaceCore
import SwiftUI

struct MapProjectionUnits: Equatable, Sendable {
    struct Ellipsoid: Equatable, Sendable {
        let semiMajorAxisMeters: Double
        let inverseFlattening: Double
    }

    enum LinearUnit: Equatable, Sendable {
        case meters
        case feet
        case native(String)
    }

    enum Kind: Equatable, Sendable {
        case linear(LinearUnit)
        case angular(name: String, radiansPerUnit: Double, ellipsoid: Ellipsoid?)
        case unavailable
    }

    let kind: Kind

    var coordinateLabel: String? {
        switch kind {
        case .linear(.meters): "m"
        case .linear(.feet): "ft"
        case .linear(.native(let name)): name.isEmpty ? nil : name
        case .angular(let name, _, _): name.isEmpty ? nil : name
        case .unavailable: nil
        }
    }

    static func from(_ evaluation: ProjectionEvaluation) -> MapProjectionUnits {
        guard evaluation.isValid else { return MapProjectionUnits(kind: .unavailable) }
        let type = ProjectionDefinitionDraft.canonicalType(evaluation.normalizedType)
        if type == "Local" {
            switch (evaluation.units ?? evaluation.normalizedValue).uppercased() {
            case "SI": return MapProjectionUnits(kind: .linear(.meters))
            case "USC", "USCUSTOMARY": return MapProjectionUnits(kind: .linear(.feet))
            default: return MapProjectionUnits(kind: .unavailable)
            }
        }

        guard evaluation.isVertical != true else { return MapProjectionUnits(kind: .unavailable) }
        let unitName = evaluation.unitName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if evaluation.isProjected == true {
            return MapProjectionUnits(kind: .linear(linearUnit(unitName)))
        }
        guard evaluation.isProjected == false else { return MapProjectionUnits(kind: .unavailable) }

        if unitName.caseInsensitiveCompare("Degrees") == .orderedSame,
           let wkt = evaluation.wkt {
            let angle = angularUnit(in: wkt) ?? (name: "°", radiansPerUnit: Double.pi / 180)
            return MapProjectionUnits(kind: .angular(name: angularLabel(angle.name), radiansPerUnit: angle.radiansPerUnit,
                ellipsoid: ellipsoid(in: wkt)))
        }
        if let wkt = evaluation.wkt, let angle = angularUnit(in: wkt) {
            return MapProjectionUnits(kind: .angular(name: angularLabel(angle.name), radiansPerUnit: angle.radiansPerUnit,
                ellipsoid: ellipsoid(in: wkt)))
        }
        return MapProjectionUnits(kind: .unavailable)
    }

    func eastWestMetersPerCoordinate(atY y: Double) -> Double? {
        guard case .angular(_, let radiansPerUnit, let ellipsoidValue) = kind,
              let ellipsoid = ellipsoidValue,
              y.isFinite,
              radiansPerUnit.isFinite, radiansPerUnit > 0 else { return nil }
        let latitude = y * radiansPerUnit
        guard latitude.isFinite, abs(latitude) <= Double.pi / 2 else { return nil }
        let flattening = ellipsoid.inverseFlattening > 0 ? 1 / ellipsoid.inverseFlattening : 0
        let eccentricitySquared = flattening * (2 - flattening)
        let sinLatitude = sin(latitude)
        let primeVerticalRadius = ellipsoid.semiMajorAxisMeters
            / sqrt(1 - eccentricitySquared * sinLatitude * sinLatitude)
        let metersPerCoordinate = primeVerticalRadius * cos(latitude) * radiansPerUnit
        return metersPerCoordinate.isFinite && metersPerCoordinate > 0 ? metersPerCoordinate : nil
    }

    private static func linearUnit(_ name: String) -> LinearUnit {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["meters", "meter", "metres", "metre", "m"].contains(normalized) { return .meters }
        if normalized == "feet" || normalized == "foot" || normalized == "ft"
            || normalized.contains("foot") || normalized.contains("ft") { return .feet }
        return .native(name)
    }

    private static func angularLabel(_ name: String) -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("degree") { return "°" }
        if normalized.contains("radian") { return "rad" }
        if normalized.contains("grad") { return "grad" }
        return name
    }

    private static func angularUnit(in wkt: String) -> (name: String, radiansPerUnit: Double)? {
        let patterns = [
            #"(?i)ANGLEUNIT\s*\[\s*"([^"]+)"\s*,\s*([+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)"#,
            #"(?i)UNIT\s*\[\s*"([^"]+)"\s*,\s*([+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)"#
        ]
        for pattern in patterns {
            guard let captures = firstCaptures(pattern, in: wkt),
                  let factor = Double(captures.1), factor.isFinite, factor > 0 else { continue }
            return (captures.0, factor)
        }
        return nil
    }

    private static func ellipsoid(in wkt: String) -> Ellipsoid? {
        let pattern = #"(?i)(?:ELLIPSOID|SPHEROID)\s*\[\s*"[^"]+"\s*,\s*([+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)\s*,\s*([+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)"#
        guard let captures = firstCaptures(pattern, in: wkt),
              let axis = Double(captures.0), let inverseFlattening = Double(captures.1),
              axis.isFinite, axis > 0, inverseFlattening.isFinite, inverseFlattening >= 0 else { return nil }
        return Ellipsoid(semiMajorAxisMeters: axis, inverseFlattening: inverseFlattening)
    }

    private static func firstCaptures(_ pattern: String, in text: String) -> (String, String)? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 3,
              let firstRange = Range(match.range(at: 1), in: text),
              let secondRange = Range(match.range(at: 2), in: text) else { return nil }
        return (String(text[firstRange]), String(text[secondRange]))
    }
}

/// Resolves coordinate labels from the same retained projection service used
/// by project setup. No map unit is inferred from the project model's SI/US
/// setting when the actual map projection reports another unit.
@MainActor
final class MapProjectionPresentation: ObservableObject {
    @Published private(set) var units: MapProjectionUnits?
    private var revision = 0

    func resolve(type: String, value: String, provider: (any ProjectionProvider)?) async {
        revision += 1
        let request = revision
        units = nil
        guard !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let provider else { return }
        let definition = ProjectionDefinitionDraft(type: ProjectionDefinitionDraft.canonicalType(type), value: value)
        do {
            let evaluation = try await provider.evaluate(definition)
            guard request == revision, !Task.isCancelled else { return }
            units = MapProjectionUnits.from(evaluation)
        } catch {
            guard request == revision, !Task.isCancelled else { return }
            units = nil
        }
    }

    func invalidate() {
        revision += 1
        units = nil
    }
}

struct MapScaleBarMeasurement: Equatable, Sendable {
    let distance: Double
    let halfDistance: Double
    let pixelWidth: Double
    let unitLabel: String
    let showsHalfDistance: Bool

    static func calculate(extent: ViewportRequest?, canvasWidth: Double,
                          units: MapProjectionUnits?) -> MapScaleBarMeasurement? {
        guard let extent, let units,
              extent.isFiniteAndOrdered,
              canvasWidth.isFinite, canvasWidth > 0 else { return nil }
        let span = extent.upperRight.x - extent.lowerLeft.x
        guard span.isFinite, span > 0 else { return nil }
        let targetPixels = min(200, canvasWidth * 0.5)
        guard targetPixels > 0 else { return nil }
        let targetNativeDistance = span * targetPixels / canvasWidth
        guard targetNativeDistance.isFinite, targetNativeDistance > 0 else { return nil }

        switch units.kind {
        case .linear(.meters):
            return rounded(target: targetNativeDistance, displayDivisor: targetNativeDistance > 10_000 ? 1_000 : 1,
                           displayUnit: targetNativeDistance > 10_000 ? "km" : "m",
                           nativeSpan: span, canvasWidth: canvasWidth)
        case .linear(.feet):
            return rounded(target: targetNativeDistance, displayDivisor: targetNativeDistance > 10_000 ? 5_280 : 1,
                           displayUnit: targetNativeDistance > 10_000 ? "mi" : "ft",
                           nativeSpan: span, canvasWidth: canvasWidth)
        case .linear(.native(let name)):
            guard !name.isEmpty else { return nil }
            return rounded(target: targetNativeDistance, displayDivisor: 1, displayUnit: name,
                           nativeSpan: span, canvasWidth: canvasWidth)
        case .angular:
            let centerY = extent.lowerLeft.y / 2 + extent.upperRight.y / 2
            guard let metersPerCoordinate = units.eastWestMetersPerCoordinate(atY: centerY) else { return nil }
            let targetMeters = targetNativeDistance * metersPerCoordinate
            guard targetMeters.isFinite, targetMeters > 0 else { return nil }
            let divisor = targetMeters > 10_000 ? 1_000.0 : 1.0
            let distance = niceDistance(targetMeters / divisor)
            guard distance.isFinite, distance > 0 else { return nil }
            let pixelWidth = distance * divisor / metersPerCoordinate / span * canvasWidth
            guard pixelWidth.isFinite, pixelWidth > 0 else { return nil }
            return MapScaleBarMeasurement(distance: distance, halfDistance: distance / 2,
                pixelWidth: pixelWidth, unitLabel: divisor == 1_000 ? "km" : "m",
                showsHalfDistance: pixelWidth >= 100 || distance <= 10_000)
        case .unavailable:
            return nil
        }
    }

    private static func rounded(target: Double, displayDivisor: Double, displayUnit: String,
                                nativeSpan: Double, canvasWidth: Double) -> MapScaleBarMeasurement? {
        let distance = niceDistance(target / displayDivisor)
        guard distance.isFinite, distance > 0 else { return nil }
        let pixelWidth = distance * displayDivisor / nativeSpan * canvasWidth
        guard pixelWidth.isFinite, pixelWidth > 0 else { return nil }
        return MapScaleBarMeasurement(distance: distance, halfDistance: distance / 2,
            pixelWidth: pixelWidth, unitLabel: displayUnit,
            showsHalfDistance: pixelWidth >= 100 || distance <= 10_000)
    }

    private static func niceDistance(_ target: Double) -> Double {
        guard target.isFinite, target > 0 else { return 0 }
        let order = pow(10, floor(log10(target)))
        return [1.0, 2.0, 5.0].map { $0 * order }.filter { $0 <= target }.max() ?? order
    }
}

struct MapPositionIndicator: View {
    let point: MapPoint?
    let units: MapProjectionUnits?

    var body: some View {
        Group {
            if let point {
                let x = point.x.formatted(.number.precision(.significantDigits(1...6)))
                let y = point.y.formatted(.number.precision(.significantDigits(1...6)))
                let suffix = units?.coordinateLabel.map { " \($0)" } ?? ""
                Text("X: \(x)   Y: \(y)" + suffix)
                    .monospacedDigit()
                    .accessibilityLabel(L10n.text("Map Position"))
            } else {
                Text("Move over the map to read coordinates")
                    .accessibilityLabel(L10n.text("Map Position"))
            }
        }
    }
}
