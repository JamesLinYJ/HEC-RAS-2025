import Foundation
import RASWorkspaceCore

public enum GlobalVectorStylePreferencesError: Error, Equatable {
    case unknownDefinition(String)
    case invalidStyle
    case encodingFailed
}

/// App-wide vector style overrides. This store deliberately owns only the
/// global default layer; local visual-context styles belong to `.vis` storage.
@MainActor
public final class GlobalVectorStylePreferences {
    public static let storageKey = "HECRAS2025.VectorSymbology.UserDefaults"

    private let defaults: UserDefaults
    private let persistenceEnabled: Bool
    private var transientOverrides: [String: VectorStyleValues] = [:]

    public init(defaults: UserDefaults = .standard, persistenceEnabled: Bool = true) {
        self.defaults = defaults
        self.persistenceEnabled = persistenceEnabled
    }

    /// Known, valid global overrides. Missing IDs inherit their source default.
    public func loadOverrides() -> [String: VectorStyleValues] {
        readPersistedOverrides().filter { SourceVectorStyleCatalog.byID[$0.key] != nil }
    }

    /// Returns the current global style or nil if the source ID is unknown.
    public func style(for definitionID: String) -> VectorStyleValues? {
        guard let definition = SourceVectorStyleCatalog.definition(for: definitionID) else { return nil }
        return loadOverrides()[definitionID] ?? definition.defaultStyle
    }

    /// Stores only app-global defaults. Setting a value back to its source
    /// default removes the override, matching the retained registry format.
    public func set(_ style: VectorStyleValues, for definitionID: String) throws {
        guard let definition = SourceVectorStyleCatalog.definition(for: definitionID) else {
            throw GlobalVectorStylePreferencesError.unknownDefinition(definitionID)
        }
        guard let validated = style.validatedForPersistence() else {
            throw GlobalVectorStylePreferencesError.invalidStyle
        }

        var values = readPersistedOverrides()
        if validated == definition.defaultStyle {
            values.removeValue(forKey: definitionID)
        } else {
            values[definitionID] = validated
        }
        try writePersistedOverrides(values)
    }

    /// Replaces all overrides for known source definitions in one defaults
    /// write. The entire input validates before storage is touched. Valid
    /// entries for IDs unknown to this build are preserved from the existing
    /// preference payload so a catalog update does not discard newer data.
    public func setOverrides(_ overrides: [String: VectorStyleValues]) throws {
        var normalized: [String: VectorStyleValues] = [:]
        for (definitionID, style) in overrides {
            guard let definition = SourceVectorStyleCatalog.definition(for: definitionID) else {
                throw GlobalVectorStylePreferencesError.unknownDefinition(definitionID)
            }
            guard let validated = style.validatedForPersistence() else {
                throw GlobalVectorStylePreferencesError.invalidStyle
            }
            if validated != definition.defaultStyle {
                normalized[definitionID] = validated
            }
        }

        var values = readPersistedOverrides()
        for definitionID in SourceVectorStyleCatalog.byID.keys {
            values.removeValue(forKey: definitionID)
        }
        values.merge(normalized) { _, replacement in replacement }
        try writePersistedOverrides(values)
    }

    private func writePersistedOverrides(_ values: [String: VectorStyleValues]) throws {
        guard persistenceEnabled else { transientOverrides = values; return }
        guard !values.isEmpty else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            defaults.set(try encoder.encode(values), forKey: Self.storageKey)
        } catch {
            throw GlobalVectorStylePreferencesError.encodingFailed
        }
    }

    /// Clears the global override dictionary without touching `.vis`, project,
    /// model, or HDF state.
    public func resetAll() {
        guard persistenceEnabled else { transientOverrides = [:]; return }
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func readPersistedOverrides() -> [String: VectorStyleValues] {
        guard persistenceEnabled else { return transientOverrides }
        guard let data = defaults.data(forKey: Self.storageKey) else { return [:] }
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any] else {
            defaults.removeObject(forKey: Self.storageKey)
            return [:]
        }

        var result: [String: VectorStyleValues] = [:]
        for (definitionID, rawValue) in object {
            guard JSONSerialization.isValidJSONObject(rawValue),
                  let encoded = try? JSONSerialization.data(withJSONObject: rawValue, options: [.sortedKeys]),
                  let decoded = try? JSONDecoder().decode(VectorStyleValues.self, from: encoded),
                  let validated = decoded.validatedForPersistence() else { continue }
            result[definitionID] = validated
        }
        return result
    }
}
