import Foundation

@MainActor
enum VectorSymbologyErrorPresentation {
    private struct Template {
        let prefix: String
        let suffix: String
        let key: String
    }

    private static let templates = [
        Template(prefix: "A current global default is required for vector style ", suffix: ".", key: "A current global default is required for vector style %@."),
        Template(prefix: "Boundary vector style ", suffix: " contains malformed colors or non-finite measurements.", key: "Boundary vector style %@ contains malformed colors or non-finite measurements."),
        Template(prefix: "Boundary vector style ", suffix: " contains unsupported or malformed values.", key: "Boundary vector style %@ contains unsupported or malformed values."),
        Template(prefix: "Boundary vector style ", suffix: " has ambiguous definitions.", key: "Boundary vector style %@ has ambiguous definitions."),
        Template(prefix: "Vector style ", suffix: " contains malformed colors or non-finite measurements.", key: "Vector style %@ contains malformed colors or non-finite measurements."),
        Template(prefix: "Vector style ", suffix: " contains unsupported or malformed values.", key: "Vector style %@ contains unsupported or malformed values."),
        Template(prefix: "Vector style ", suffix: " has ambiguous definitions.", key: "Vector style %@ has ambiguous definitions."),
        Template(prefix: "Vector style ", suffix: " has an unsupported persisted style type.", key: "Vector style %@ has an unsupported persisted style type."),
        Template(prefix: "Vector condition group ", suffix: " is ambiguous.", key: "Vector condition group %@ is ambiguous.")
    ]

    static func text(_ raw: String) -> String {
        for template in templates where raw.hasPrefix(template.prefix) && raw.hasSuffix(template.suffix) {
            let start = raw.index(raw.startIndex, offsetBy: template.prefix.count)
            let end = raw.index(raw.endIndex, offsetBy: -template.suffix.count)
            guard start <= end else { continue }
            let argument = String(raw[start..<end])
            guard !argument.isEmpty else { continue }
            return L10n.format(template.key, argument)
        }
        return L10n.text(raw)
    }
}
