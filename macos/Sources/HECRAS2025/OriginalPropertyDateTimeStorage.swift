import Foundation

/// Edits the visible date or time segment in the source value's existing
/// representation. DateInputBox and TimeInputBox edit a DateTime component;
/// serializing through Date would otherwise change its wall time or UTC offset.
enum OriginalPropertyDateTimeStorage {
    static let unpreservableFormatIssue = "Cannot preserve the source date/time format."

    private struct DateTimeParts {
        let date: String
        let separator: Character
        let time: String
        let suffix: String
    }

    static func dateText(from rawValue: String) -> String? {
        if rawValue.count == 10, OriginalDateTimeDraftCodec.parseCanonicalDate(rawValue) != nil {
            return rawValue
        }
        return dateTimeParts(from: rawValue)?.date
    }

    static func timeText(from rawValue: String) -> String? {
        dateTimeParts(from: rawValue)?.time
    }

    static func replacingDate(_ dateText: String, in rawValue: String) -> String? {
        guard OriginalDateTimeDraftCodec.parseCanonicalDate(dateText) != nil else { return nil }
        guard !rawValue.isEmpty else { return "\(dateText)T00:00:00" }
        if rawValue.count == 10, OriginalDateTimeDraftCodec.parseCanonicalDate(rawValue) != nil {
            return dateText
        }
        guard let parts = dateTimeParts(from: rawValue) else { return nil }
        return "\(dateText)\(parts.separator)\(parts.time)\(zeroFraction(parts.suffix))"
    }

    static func replacing(dateText: String, timeText: String, in rawValue: String) -> String? {
        replacing(
            dateText: dateText, timeText: timeText,
            dateTouched: true, timeTouched: true, in: rawValue
        )
    }

    static func replacing(
        dateText: String,
        timeText: String,
        dateTouched: Bool,
        timeTouched: Bool,
        in rawValue: String,
        resetSubsecondPrecision: Bool = false
    ) -> String? {
        guard dateTouched || timeTouched else { return rawValue }
        var updated = rawValue
        if dateTouched {
            guard let withDate = replacingDate(dateText, in: updated) else { return nil }
            updated = withDate
        }
        if timeTouched {
            guard let withTime = replacingTime(timeText, in: updated) else { return nil }
            updated = withTime
        }
        if resetSubsecondPrecision, let parts = dateTimeParts(from: updated) {
            updated = "\(parts.date)\(parts.separator)\(parts.time)\(zeroFraction(parts.suffix))"
        }
        return updated
    }

    static func replacingTime(_ timeText: String, in rawValue: String) -> String? {
        guard OriginalDateTimeDraftCodec.parseCanonicalTime(timeText) != nil else { return nil }
        guard !rawValue.isEmpty else { return "0001-01-01T\(timeText)" }
        if rawValue.count == 10, OriginalDateTimeDraftCodec.parseCanonicalDate(rawValue) != nil {
            return "\(rawValue)T\(timeText)"
        }
        guard let parts = dateTimeParts(from: rawValue) else { return nil }
        // Standalone time edits retain the existing serialized suffix. The
        // combined DateTimeInputBox route explicitly requests tick truncation.
        return "\(parts.date)\(parts.separator)\(timeText)\(parts.suffix)"
    }

    static func pickerDate(dateText: String, timeText: String) -> Date? {
        OriginalDateTimeDraftCodec.combineCanonical(dateText: dateText, timeText: timeText)
    }

    private static func dateTimeParts(from rawValue: String) -> DateTimeParts? {
        let characters = Array(rawValue)
        guard characters.count >= 19 else { return nil }
        let date = String(characters[0..<10])
        let separator = characters[10]
        let time = String(characters[11..<19])
        let suffix = String(characters.dropFirst(19))
        guard OriginalDateTimeDraftCodec.parseCanonicalDate(date) != nil,
              separator == "T" || separator == " ",
              OriginalDateTimeDraftCodec.parseCanonicalTime(time) != nil,
              isSupportedSuffix(suffix) else { return nil }
        return DateTimeParts(date: date, separator: separator, time: time, suffix: suffix)
    }

    private static func zeroFraction(_ suffix: String) -> String {
        guard suffix.first == "." else { return suffix }
        let fraction = suffix.dropFirst().prefix(while: { $0.isNumber })
        guard !fraction.isEmpty else { return suffix }
        let remainder = suffix.dropFirst(1 + fraction.count)
        return ".\(String(repeating: "0", count: fraction.count))\(remainder)"
    }

    private static func isSupportedSuffix(_ suffix: String) -> Bool {
        guard !suffix.isEmpty else { return true }
        var remainder = suffix[...]
        if remainder.first == "." {
            remainder = remainder.dropFirst()
            let fraction = remainder.prefix(while: { $0.isNumber })
            guard !fraction.isEmpty else { return false }
            remainder = remainder.dropFirst(fraction.count)
        }
        guard !remainder.isEmpty else { return true }
        if remainder == "Z" { return true }
        guard let sign = remainder.first, sign == "+" || sign == "-" else { return false }
        let offset = remainder.dropFirst()
        let digits = offset.filter { $0.isNumber }
        return (digits.count == 2 || digits.count == 4) &&
            (offset.count == digits.count || (offset.count == digits.count + 1 && offset.contains(":")))
    }
}
