import Foundation

enum OriginalNumberInputStatus: Equatable {
    case empty
    case invalid
    case belowMinimum(Double)
    case aboveMaximum(Double)
    case valid(Double)
}

enum OriginalNumberInputValidator {
    static func evaluate(_ rawValue: String, minimum: Double?, maximum: Double?) -> OriginalNumberInputStatus {
        guard !rawValue.isEmpty else { return .empty }
        guard let value = Double(rawValue), value.isFinite else { return .invalid }
        if let minimum, value < minimum { return .belowMinimum(minimum) }
        if let maximum, value > maximum { return .aboveMaximum(maximum) }
        return .valid(value)
    }
}
