import SwiftUI

/// Native counterpart of InterpolatedSurfaceFillEditor. The original control is
/// read-only and displays only the source fill's maximum and minimum values.
struct InterpolatedSurfaceFillEditorView: View {
    let context: InterpolatedSurfaceFillContext?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            OriginalTextPropertyItem(title: "Maximum", value: formatted(context?.maxValue))
            OriginalTextPropertyItem(title: "Minimum", value: formatted(context?.minValue))
        }
    }

    private func formatted(_ value: Double?) -> String {
        guard let value else { return "—" }
        return Self.doubleToSigFigString(value, significantDigits: 3)
    }

    /// Mirrors NumberConverters.DoubleToSigFigString for its three-significant-
    /// digit display, including fixed decimal places below one and grouping above.
    private static func doubleToSigFigString(_ value: Double, significantDigits: Int) -> String {
        guard !value.isNaN, value != Double.greatestFiniteMagnitude, significantDigits > 0 else { return "" }
        if value == 0 { return "0" }
        guard value.isFinite else { return value.sign == .minus ? "−∞" : "∞" }

        let magnitude = abs(value)
        let exponent = Int(floor(log10(magnitude)))
        let fractionDigits: Int
        if magnitude >= 1 {
            let integerDigits = exponent + 1
            fractionDigits = max(0, significantDigits - integerDigits)
        } else {
            fractionDigits = max(0, significantDigits - exponent - 1)
        }

        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = magnitude >= 1
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = min(fractionDigits, 340)
        return formatter.string(from: NSNumber(value: value)) ?? ""
    }
}
