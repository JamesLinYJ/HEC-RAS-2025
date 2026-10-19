import Foundation

enum OsmOperator: String, CaseIterable, Decodable, Sendable {
    case exists = "Exists", notExists = "NotExists", equals = "Equals", notEquals = "NotEquals"
    case matches = "Matches", notMatches = "NotMatches", oneOf = "OneOf"
    var requiresValue: Bool { self != .exists && self != .notExists }
    var title: String {
        switch self {
        case .exists: "exists"
        case .notExists: "does not exist"
        case .equals: "="
        case .notEquals: "!="
        case .matches: "matches (regex)"
        case .notMatches: "does not match (regex)"
        case .oneOf: "one of (a;b)"
        }
    }
}
struct OsmFilter: Identifiable, Decodable, Sendable, Equatable {
    var id = UUID()
    var key: String
    var comparison: OsmOperator
    var value: String
    enum CodingKeys: String, CodingKey { case key, comparison = "operator", value }
    init(key: String = "", comparison: OsmOperator = .exists, value: String = "") { self.key = key; self.comparison = comparison; self.value = value }
}
struct OsmClause: Identifiable, Decodable, Sendable, Equatable {
    var id = UUID()
    var kinds: [String]
    var filters: [OsmFilter]
    enum CodingKeys: String, CodingKey { case kinds, filters }
    init(kinds: [String] = ["Node", "Way", "Relation"], filters: [OsmFilter] = [.init()]) { self.kinds = kinds; self.filters = filters }
}
struct OsmPreset: Identifiable, Decodable, Sendable {
    let id: String
    let name: String
    let description: String
    let clauses: [OsmClause]
}
struct FeatureQueryOptions: Decodable, Sendable {
    struct Layer: Identifiable, Decodable, Sendable { let id: String; let name: String; let merged: Bool }
    struct Format: Identifiable, Decodable, Sendable { let id: String; let name: String; let `extension`: String }
    let osmPresets: [OsmPreset]
    let nldLayers: [Layer]
    let exportFormats: [Format]
    static let source: Self = {
        guard let url = Bundle.module.url(forResource: "feature-query-options", withExtension: "json"),
              let data = try? Data(contentsOf: url), let result = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self(osmPresets: [], nldLayers: [], exportFormats: [])
        }
        return result
    }()
}

// This is the source query builder's UI text generation, not the query client.
// Coordinates, projection, QL sanitization and network execution remain in its adapter.
@MainActor
struct OSMQueryDraft: Sendable, Equatable {
    var selectedPresetID: String?
    var label = "Query"
    var timeoutSeconds = 180
    var clauses: [OsmClause] = []
    var rawQL = ""
    var builderError: String?

    init() { if let preset = FeatureQueryOptions.source.osmPresets.first { load(preset) } }
    mutating func load(_ preset: OsmPreset) {
        selectedPresetID = preset.id; label = preset.id; timeoutSeconds = 180
        clauses = preset.clauses.map { clause in
            OsmClause(kinds: clause.kinds, filters: clause.filters.map { .init(key: $0.key, comparison: $0.comparison, value: $0.value) })
        }
        sync()
    }
    mutating func editBuilder(_ action: (inout Self) -> Void) { action(&self); selectedPresetID = nil; sync() }
    mutating func editQL(_ value: String) { rawQL = value; selectedPresetID = nil }
    private mutating func sync() {
        do { rawQL = try templateQL(); builderError = nil }
        catch { builderError = error.localizedDescription; rawQL = "// " + error.localizedDescription }
    }
    func templateQL() throws -> String {
        guard !clauses.isEmpty else { throw QueryError("Add at least one search clause before querying.") }
        var output = "[out:json][timeout:\(timeoutSeconds)];\n(\n"
        for clause in clauses {
            guard !clause.kinds.isEmpty else { throw QueryError("A search clause has no element types selected (node, way, or relation).") }
            let tokens = ["Node", "Way", "Relation"].filter { clause.kinds.contains($0) }
            let kinds = tokens.count == 3 ? ["nwr"] : tokens.map { $0.lowercased() }
            let filters = try clause.filters.map(Self.filterQL).joined()
            for kind in kinds { output += "  \(kind)\(filters)({{bbox}});\n" }
        }
        return output + ");\nout geom;"
    }
    private static func escape(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    private static func trim(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func filterQL(_ filter: OsmFilter) throws -> String {
        guard !trim(filter.key).isEmpty else { throw QueryError("A tag filter is missing its key.") }
        guard !filter.comparison.requiresValue || !trim(filter.value).isEmpty else {
            throw QueryError(L10n.format("Tag filter \"%@\" needs a value for the \"%@\" comparison.", filter.key, filter.comparison.rawValue))
        }
        let key = escape(trim(filter.key)), value = escape(trim(filter.value))
        switch filter.comparison {
        case .exists: return "[\"\(key)\"]"
        case .notExists: return "[!\"\(key)\"]"
        case .equals: return "[\"\(key)\"=\"\(value)\"]"
        case .notEquals: return "[\"\(key)\"!=\"\(value)\"]"
        case .matches: return "[\"\(key)\"~\"\(value)\"]"
        case .notMatches: return "[\"\(key)\"!~\"\(value)\"]"
        case .oneOf:
            // .NET Regex.Escape escapes this exact set, including whitespace.
            let specials = Set("\\*+?|{[()^$.# \t\n\r\u{000C}")
            let values = filter.value.split(separator: ";").map { trim(String($0)) }.filter { !$0.isEmpty }.map { part in
                part.map { character -> String in
                    switch character { case "\t": "\\t"; case "\n": "\\n"; case "\r": "\\r"; case "\u{000C}": "\\f"; default: (specials.contains(character) ? "\\" : "") + String(character) }
                }.joined()
            }
            guard !values.isEmpty else { throw QueryError(L10n.format("Tag filter \"%@\" lists no values.", filter.key)) }
            return "[\"\(key)\"~\"\(escape("^(" + values.joined(separator: "|") + ")$"))\"]"
        }
    }
    private struct QueryError: LocalizedError {
        let message: String
        @MainActor init(_ message: String) { self.message = L10n.text(message) }
        var errorDescription: String? { message }
    }
}
