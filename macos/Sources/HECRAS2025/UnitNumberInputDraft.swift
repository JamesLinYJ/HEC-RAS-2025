import Foundation

enum OriginalUnitNumberInputOwner: Hashable, Sendable {
    case field(String)
    case tableCell(tableID: String, rowID: String, columnID: String)

    var stableKey: String {
        let parts: [String]
        switch self {
        case .field(let fieldID): parts = ["field", fieldID]
        case .tableCell(let tableID, let rowID, let columnID): parts = ["tableCell", tableID, rowID, columnID]
        }
        return parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}

struct OriginalUnitNumberInputContext: Equatable, Sendable {
    let editorIdentity: String
    let sourceValue: String
    let fieldBindingID: String?
    let sourceType: String
    let selectionID: String
    let sourceID: String
    let sourceUnitTypeID: String?
    let unitID: String
    let unitTypeID: String?
    let scale: Double
    let offset: Double
    let localeIdentifier: String
}

struct OriginalUnitNumberInputDraft: Equatable, Sendable {
    var context: OriginalUnitNumberInputContext
    var rawDisplayText: String
    var issueKey: String
    var isStale: Bool

    init(context: OriginalUnitNumberInputContext, rawDisplayText: String,
         issueKey: String = OriginalUnitNumberInputIssue.invalidNumber, isStale: Bool = false) {
        self.context = context
        self.rawDisplayText = rawDisplayText
        self.issueKey = issueKey
        self.isStale = isStale
    }
}

enum OriginalUnitNumberInputIssue {
    static let invalidNumber = "Enter a valid number."
    static let staleNumber = "This number changed while you were editing. Discard it and enter again."
    static let blockedBeforeSave = "Complete or discard the invalid number before saving."
}

enum OriginalUnitNumberInputCodec {
    static func parse(_ text: String, locale: Locale) -> Double? {
        guard !text.isEmpty else { return nil }
        return parse(text, locale: locale, style: .decimal)
            ?? parse(text, locale: locale, style: .scientific)
    }

    private static func parse(_ text: String, locale: Locale, style: NumberFormatter.Style) -> Double? {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = style
        formatter.isLenient = false
        formatter.usesGroupingSeparator = true
        var consumed = NSRange(location: 0, length: (text as NSString).length)
        var object: AnyObject?
        do {
            try formatter.getObjectValue(&object, for: text, range: &consumed)
            if let number = object as? NSNumber,
               consumed.location == 0,
               consumed.length == (text as NSString).length {
                let value = number.doubleValue
                if value.isFinite { return value }
            }
        } catch { /* Try the recognized incomplete decimal prefix below. */ }
        if style == .decimal, let separator = formatter.decimalSeparator, text.hasSuffix(separator) {
            return parse(text + "0", locale: locale, style: .decimal)
        }
        return nil
    }

    static func format(_ value: Double, locale: Locale) -> String {
        String(format: "%.8G", locale: locale, arguments: [value])
    }

    static func fieldText(sourceValue: String, unit: DisplayUnitChoice, locale: Locale,
                          focusedText: String?) -> String {
        if let focusedText { return focusedText }
        guard let source = Double(sourceValue), source.isFinite else { return "" }
        return format(unit.displayed(source), locale: locale)
    }

    static func sourceValue(fromDisplayValue value: Double, using choice: DisplayUnitChoice) -> String? {
        guard value.isFinite else { return nil }
        let source = choice.source(value)
        guard source.isFinite else { return nil }
        return String(source)
    }
}
