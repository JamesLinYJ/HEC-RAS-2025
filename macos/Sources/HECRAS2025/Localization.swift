import Foundation

@MainActor
enum L10n {
    static var language = "System"
    static var bundle: Bundle {
        let identifier = language == "System" ? (Locale.preferredLanguages.first ?? "en") : language
        let resourceLanguage = identifier.hasPrefix("zh") ? "zh-Hans" : "en"
        if let path = Bundle.module.path(forResource: resourceLanguage, ofType: "lproj"), let bundle = Bundle(path: path) { return bundle }
        return .module
    }
    static func text(_ key: String) -> String {
        let resources = bundle
        let translated = resources.localizedString(forKey: key, value: key, table: nil)
        guard translated == key else { return translated }
        // Source operation failures combine fixed headings with actual model
        // diagnostics. Translate known lines while retaining unknown source
        // messages, file paths and log values verbatim.
        return key.components(separatedBy: "\n").map { line in
            let localizedLine = resources.localizedString(forKey: line, value: line, table: nil)
            if localizedLine != line { return localizedLine }
            // ArgumentException adds the source parameter to a fixed message.
            // Translate only an independently known heading, preserving the
            // actual parameter identifier and all unknown source diagnostics.
            guard line.hasSuffix("')"),
                  let suffix = line.range(of: " (Parameter '", options: .backwards) else { return line }
            let heading = String(line[..<suffix.lowerBound])
            let localizedHeading = resources.localizedString(forKey: heading, value: heading, table: nil)
            guard localizedHeading != heading else { return line }
            let parameterEnd = line.index(line.endIndex, offsetBy: -2)
            guard suffix.upperBound <= parameterEnd else { return line }
            let parameter = line[suffix.upperBound..<parameterEnd]
            let label = resources.localizedString(forKey: "Parameter", value: "Parameter", table: nil)
            return localizedHeading + " (" + label + " '" + String(parameter) + "')"
        }.joined(separator: "\n")
    }
    static func format(_ key: String, _ arguments: CVarArg...) -> String { String(format: text(key), locale: Locale(identifier: language == "System" ? Locale.current.identifier : language), arguments: arguments) }
}
