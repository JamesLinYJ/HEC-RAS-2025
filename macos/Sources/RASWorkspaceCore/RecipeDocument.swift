import Foundation

public struct RecipeParameter: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let kind: String
    public let defaultValue: String
}
public struct RecipeCommand: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let parameters: [RecipeParameter]
    public let palette: Bool
    public let paletteDefaults: [String: String]
    public let aliases: [String]
    public let source: String
}
public struct RecipeStep: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let command: String
    public var values: [String: String]
    public init(command: RecipeCommand, paletteDefaults: Bool = false) {
        id = UUID(); self.command = command.id
        values = Dictionary(uniqueKeysWithValues: command.parameters.map { ($0.id, $0.defaultValue) })
        if paletteDefaults { values.merge(command.paletteDefaults) { _, newer in newer } }
    }
}
public enum RecipeDocument {
    // The original config grammar is a list of named calls; parameter names
    // and commands are case-insensitive. This code never executes mesh steps.
    public static func parse(_ text: String, commands: [RecipeCommand], meshType: String? = nil) throws -> [RecipeStep] {
        var parser = Parser(text: text, commands: commands, meshType: meshType)
        return try parser.parse()
    }

    /// Resolves the retained RecipeBuilder's Default() token for one selected
    /// conceptual-mesh PatchType. A missing mesh type deliberately leaves the
    /// token as a normal recipe step so callers without that source context do
    /// not invent a default sequence.
    public static func defaultSteps(meshType: String, commands: [RecipeCommand]) throws -> [RecipeStep] {
        let sequence: [(String, [String: String])]
        switch meshType {
        case "Quad":
            sequence = [("Smooth", [:]), ("Split", ["threshold": "0.4"])]
        case "TrianglePaver":
            sequence = [("SwapEdges", [:]), ("Smooth", [:]), ("RemoveFaces", ["threshold": "0"]),
                ("Smooth", [:]), ("Split", ["threshold": "0.1"])]
        case "Cartesian":
            sequence = [("SwapEdges", [:])]
        case "OneD", "Empty":
            sequence = []
        default:
            throw ProjectFileError.invalid("Unrecognized conceptual-mesh patch type.")
        }
        return try sequence.map { name, overrides in
            guard let command = commands.first(where: { $0.id.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw ProjectFileError.invalid("The source recipe command is unavailable.")
            }
            var step = RecipeStep(command: command)
            for parameter in command.parameters {
                step.values[parameter.id] = try normalized(parameter.defaultValue, kind: parameter.kind)
            }
            for (parameterID, rawValue) in overrides {
                guard let parameter = command.parameters.first(where: {
                    $0.id.caseInsensitiveCompare(parameterID) == .orderedSame
                }) else {
                    throw ProjectFileError.invalid("The source recipe parameter is unavailable.")
                }
                step.values[parameter.id] = try normalized(rawValue, kind: parameter.kind)
            }
            return step
        }
    }
    public static func serialize(_ steps: [RecipeStep], commands: [RecipeCommand]) throws -> String {
        try steps.map { step in
            guard let command = commands.first(where: { $0.id == step.command }) else { throw ProjectFileError.invalid("Unrecognized recipe step.") }
            let parameters = try command.parameters.map { parameter in
                let value = try normalized(step.values[parameter.id] ?? parameter.defaultValue, kind: parameter.kind)
                return parameter.id + "=" + value
            }
            return command.id + "(" + parameters.joined(separator: ", ") + ")"
        }.joined(separator: "\n")
    }
    private static func normalized(_ raw: String, kind: String) throws -> String {
        switch kind {
        case "boolean":
            if ["true", "t", "1", "yes"].contains(raw.lowercased()) { return "True" }
            if ["false", "f", "0", "no"].contains(raw.lowercased()) { return "False" }
        case "integer":
            if let value = Int32(raw) { return String(value) }
        default:
            if let value = Double(raw), value.isFinite {
                // The original value grammar does not accept exponent tokens.
                let formatter = NumberFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.numberStyle = .decimal; formatter.usesGroupingSeparator = false
                formatter.maximumFractionDigits = 340; formatter.maximumIntegerDigits = 309
                if let result = formatter.string(from: NSNumber(value: value)) { return result }
            }
        }
        throw ProjectFileError.invalid("Invalid recipe parameter value.")
    }
    private struct Parser {
        let characters: [Character]
        let commands: [RecipeCommand]
        let meshType: String?
        var position = 0
        init(text: String, commands: [RecipeCommand], meshType: String?) {
            characters = Array(text); self.commands = commands; self.meshType = meshType
        }
        mutating func skip() {
            while position < characters.count {
                if characters[position].isWhitespace { position += 1 }
                else if characters[position] == "#" {
                    // Generalize the original CR-only comment reader to Mac
                    // LF and Windows CRLF without changing command meaning.
                    while position < characters.count, !characters[position].isNewline { position += 1 }
                } else { return }
            }
        }
        mutating func identifier() throws -> String {
            skip(); let start = position
            guard position < characters.count, characters[position].isLetter else { throw ProjectFileError.invalid("Expected a recipe identifier.") }
            position += 1
            while position < characters.count, characters[position].isLetter || characters[position].isNumber { position += 1 }
            return String(characters[start..<position])
        }
        mutating func consume(_ character: Character) -> Bool {
            skip(); guard position < characters.count, characters[position] == character else { return false }
            position += 1; return true
        }
        mutating func require(_ character: Character) throws {
            guard consume(character) else { throw ProjectFileError.invalid("Invalid recipe syntax.") }
        }
        mutating func parse() throws -> [RecipeStep] {
            var result: [RecipeStep] = []
            while true {
                skip(); if position == characters.count { return result }
                let name = try identifier()
                guard let command = commands.first(where: { $0.id.caseInsensitiveCompare(name) == .orderedSame || $0.aliases.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) }) else { throw ProjectFileError.invalid("Unrecognized recipe step.") }
                try require("("); var step = RecipeStep(command: command)
                for parameter in command.parameters {
                    step.values[parameter.id] = try RecipeDocument.normalized(parameter.defaultValue, kind: parameter.kind)
                }
                if !consume(")") {
                    while true {
                        let key = try identifier()
                        guard let parameter = command.parameters.first(where: { $0.id.caseInsensitiveCompare(key) == .orderedSame }) else { throw ProjectFileError.invalid("Unrecognized recipe parameter.") }
                        try require("="); skip(); let start = position
                        while position < characters.count, ![",", ")", "#"].contains(characters[position]), !characters[position].isWhitespace { position += 1 }
                        let raw = String(characters[start..<position])
                        if raw.range(of: "^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)$|^[A-Za-z][A-Za-z0-9]*$", options: .regularExpression) == nil { throw ProjectFileError.invalid("Invalid recipe parameter value.") }
                        step.values[parameter.id] = try RecipeDocument.normalized(raw, kind: parameter.kind)
                        if consume(")") { break }
                        try require(",")
                        if consume(")") { break } // Original parser accepts a final comma.
                    }
                }
                if step.command == "Default", let meshType {
                    result.append(contentsOf: try RecipeDocument.defaultSteps(meshType: meshType, commands: commands))
                } else {
                    result.append(step)
                }
                _ = consume(";") || consume(",")
            }
        }
    }
}
