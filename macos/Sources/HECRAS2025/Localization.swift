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
            localizedDiagnosticLine(line, resources: resources)
        }.joined(separator: "\n")
    }

    private static func localizedDiagnosticLine(_ line: String, resources: Bundle) -> String {
        let localizedLine = resources.localizedString(forKey: line, value: line, table: nil)
        if localizedLine != line { return localizedLine }

        // GeometryVectorImportService emits this fixed template with only the
        // source basename inserted. Keep that basename (including punctuation)
        // as opaque data while translating the sentence around it.
        let noLineFeaturesSuffix = "' contains no line or polygon features to import."
        if line.hasPrefix("'"), line.hasSuffix(noLineFeaturesSuffix) {
            let fileNameStart = line.index(after: line.startIndex)
            let fileNameEnd = line.index(line.endIndex, offsetBy: -noLineFeaturesSuffix.count)
            if fileNameStart <= fileNameEnd {
                let fileName = String(line[fileNameStart..<fileNameEnd])
                return format("'%@' contains no line or polygon features to import.", fileName)
            }
        }

        // GeometryVectorImportService interpolates a source ordinal as decimal
        // digits. Only translate that exact diagnostic and preserve its value.
        let featurePrefix = "Shapefile feature "
        let nonFiniteSuffix = " contains a non-finite coordinate."
        if line.hasPrefix(featurePrefix), line.hasSuffix(nonFiniteSuffix) {
            let ordinalStart = line.index(line.startIndex, offsetBy: featurePrefix.count)
            let ordinalEnd = line.index(line.endIndex, offsetBy: -nonFiniteSuffix.count)
            let digits = line[ordinalStart..<ordinalEnd]
            if !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
               let ordinal = Int32(digits) {
                return format("Shapefile feature %d contains a non-finite coordinate.", ordinal)
            }
        }

        // NewShapefileService has a closed set of shape types. Do not treat an
        // arbitrary enum, protocol token or data string as a localizable value.
        let emptyFamilyPrefix = "The retained Shapefile writer could not create an empty "
        let emptyFamilySuffix = " family."
        if line.hasPrefix(emptyFamilyPrefix), line.hasSuffix(emptyFamilySuffix) {
            let shapeStart = line.index(line.startIndex, offsetBy: emptyFamilyPrefix.count)
            let shapeEnd = line.index(line.endIndex, offsetBy: -emptyFamilySuffix.count)
            let shapeType = String(line[shapeStart..<shapeEnd])
            if ["Point", "Polyline", "Polygon"].contains(shapeType) {
                return format("The retained Shapefile writer could not create an empty %@ family.", shapeType)
            }
        }

        // ExportOutputCommit appends this exact marker and a comma-separated
        // list of cleanup paths. Translate only the marker; keep both the
        // original writer diagnostic and cleanup details untouched unless a
        // writer prefix itself matches a known source template below.
        let rollbackMarker = " The incomplete shapefile family could not be rolled back: "
        if let marker = line.range(of: rollbackMarker, options: .backwards),
           marker.lowerBound > line.startIndex, marker.upperBound < line.endIndex {
            // Preserve the marker's separator so the unknown preceding
            // diagnostic keeps its original spacing before the translation.
            let separatorEnd = line.index(after: marker.lowerBound)
            let separator = String(line[marker.lowerBound..<separatorEnd])
            let precedingDiagnostic = String(line[..<marker.lowerBound])
            let cleanupDetails = String(line[marker.upperBound...])
            let localizedDiagnostic = localizedDiagnosticLine(precedingDiagnostic, resources: resources)
            return localizedDiagnostic + separator + format(
                "The incomplete shapefile family could not be rolled back: %@", cleanupDetails)
        }

        // DepthShapefileExportService prepends this fixed heading to backend
        // writer messages. Keep the complete dynamic detail verbatim.
        let writerFailurePrefix = "The retained shapefile writer failed: "
        if line.hasPrefix(writerFailurePrefix) {
            let detailsStart = line.index(line.startIndex, offsetBy: writerFailurePrefix.count)
            return format(writerFailurePrefix + "%@", String(line[detailsStart...]))
        }

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
    }
    static func format(_ key: String, _ arguments: CVarArg...) -> String { String(format: text(key), locale: Locale(identifier: language == "System" ? Locale.current.identifier : language), arguments: arguments) }
}
