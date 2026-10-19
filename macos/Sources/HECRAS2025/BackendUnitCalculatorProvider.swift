import Foundation
import RASWorkspaceCore

/// Adapter for the original UnitCalculator. It sends unit identifiers and a
/// direction to the source host; conversion math remains in BaseUnitType.
@MainActor
final class BackendUnitCalculatorProvider: ToolProvider {
    private let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func prepare(_ request: ToolRequest) async throws -> DataToolPresentation {
        try await presentation(for: request, calculate: request.operation == .calculate)
    }

    func perform(_ request: ToolRequest) async throws -> DataToolPresentation {
        try await presentation(for: request, calculate: true)
    }

    func execute(_ request: ToolRequest) async throws {
        throw DataToolError.unavailable
    }

    /// Loads the retained BaseUnitType catalog for a typed source unit. This
    /// is used by NumberBox-style inline calculators whose source unit comes
    /// from DisplayUnitData rather than a guessed unit label.
    func loadUnits(fromUnitID: String, toUnitID: String? = nil) async throws -> UnitCalculatorPresentation {
        guard !fromUnitID.isEmpty else { throw DataToolError.unavailable }
        let loaded = try await client.request(
            "unitCalculator.load",
            parameters: LoadRequest(fromUnitId: fromUnitID, toUnitId: toUnitID),
            as: LoadResult.self
        )
        try Task.checkCancellation()
        guard loaded.fromUnitId == fromUnitID else { throw DataToolError.unavailable }
        return Self.presentation(for: loaded)
    }

    /// Converts through the retained BaseUnitType.TryConvertTo implementation.
    func convert(
        value: Double,
        fromUnitID: String,
        toUnitID: String,
        direction: UnitCalculatorConversionDirection = .fromTo
    ) async throws -> Double {
        guard value.isFinite, !fromUnitID.isEmpty, !toUnitID.isEmpty else { throw DataToolError.unavailable }
        let result = try await client.request(
            "unitCalculator.convert",
            parameters: ConvertRequest(
                fromUnitId: fromUnitID,
                toUnitId: toUnitID,
                value: value,
                direction: direction
            ),
            as: ConvertResult.self
        )
        try Task.checkCancellation()
        guard result.value.isFinite else { throw DataToolError.unavailable }
        return result.value
    }

    private func presentation(for request: ToolRequest, calculate: Bool) async throws -> DataToolPresentation {
        guard request.kind == ToolKind.unitCalculator.id else { throw DataToolError.unavailable }

        let fromKey = "UnitCalculator/FromSelectedUnit"
        let toKey = "UnitCalculator/ToSelectedUnit"
        let fromInputKey = "UnitCalculator/FromInput"
        let toOutputKey = "UnitCalculator/ToOutput"
        let requestedFromID = request.fields[fromKey].flatMap { $0.isEmpty ? nil : $0 }
        let requestedToID = request.fields[toKey].flatMap { $0.isEmpty ? nil : $0 }
        let loaded = try await client.request(
            "unitCalculator.load",
            parameters: LoadRequest(fromUnitId: requestedFromID, toUnitId: requestedToID),
            as: LoadResult.self
        )
        try Task.checkCancellation()

        var fields = request.fields
        if fields[fromInputKey] == nil { fields[fromInputKey] = "0" }
        if fields[toOutputKey] == nil { fields[toOutputKey] = "0" }
        fields[fromKey] = loaded.fromUnitId ?? ""
        fields[toKey] = loaded.toUnitId ?? ""

        let targetIDIsValid = requestedToID.map { id in loaded.toUnits.contains(where: { $0.id == id }) } ?? false
        let targetSelectionMessage = requestedToID != nil && loaded.fromUnitId != nil && !targetIDIsValid
            ? L10n.text("Choose a target unit from the selected unit family.") : ""

        if calculate, targetIDIsValid, let fromID = loaded.fromUnitId, let toID = loaded.toUnitId,
           let trigger = request.triggeringField,
           let calculation = calculation(for: trigger) {
            let value = calculation.key == fromInputKey
                ? UnitCalculatorNumberFormat.number(from: fields[fromInputKey] ?? "")
                : UnitCalculatorNumberFormat.number(from: fields[toOutputKey] ?? "")
            if let value {
                let result = try await client.request(
                    "unitCalculator.convert",
                    parameters: ConvertRequest(
                        fromUnitId: fromID,
                        toUnitId: toID,
                        value: value,
                        direction: calculation.direction
                    ),
                    as: ConvertResult.self
                )
                try Task.checkCancellation()
                fields[calculation.outputKey] = String(result.value)
            }
        }

        let calculator = Self.presentation(for: loaded)
        return DataToolPresentation(
            editor: EditorSnapshot(fields: fields, rows: [:], samples: [:], canEdit: true, images: [:]),
            message: targetSelectionMessage,
            unitCalculator: calculator
        )
    }

    private func calculation(for trigger: String) -> Calculation? {
        switch trigger {
        case "UnitCalculator/FromInput", "UnitCalculator/FromSelectedUnit":
            return .init(key: "UnitCalculator/FromInput", outputKey: "UnitCalculator/ToOutput", direction: .fromTo)
        case "UnitCalculator/ToOutput", "UnitCalculator/ToSelectedUnit":
            return .init(key: "UnitCalculator/ToOutput", outputKey: "UnitCalculator/FromInput", direction: .toFrom)
        default:
            return nil
        }
    }

    private static func presentation(for loaded: LoadResult) -> UnitCalculatorPresentation {
        let sourceUnits = loaded.fromUnits.map {
            UnitCalculatorUnitChoice(id: $0.id, name: $0.name, unitTypeName: $0.unitTypeName)
        }
        let targetUnits = loaded.toUnits.map {
            EditorChoice(id: $0.id, title: $0.name, titleIsUserData: true)
        }
        return UnitCalculatorPresentation(
            fromUnitName: loaded.fromUnitName ?? "",
            fromUnits: sourceUnits,
            toUnits: targetUnits,
            fromUnitID: loaded.fromUnitId ?? ""
        )
    }

    private struct LoadRequest: Encodable, Sendable {
        let fromUnitId: String?
        let toUnitId: String?
    }
    private struct ConvertRequest: Encodable, Sendable {
        let fromUnitId: String
        let toUnitId: String
        let value: Double
        let direction: UnitCalculatorConversionDirection
    }
    enum UnitCalculatorConversionDirection: String, Encodable, Sendable {
        case fromTo = "FromTo"
        case toFrom = "ToFrom"
    }
    private struct LoadResult: Decodable, Sendable {
        let fromUnits: [Unit]
        let toUnits: [Unit]
        let fromUnitId: String?
        let fromUnitName: String?
        let unitTypeName: String?
        let toUnitId: String?

        struct Unit: Decodable, Sendable {
            let id: String
            let name: String
            let unitTypeName: String
        }
    }
    private struct ConvertResult: Decodable, Sendable { let value: Double }
    private struct Calculation {
        let key: String
        let outputKey: String
        let direction: UnitCalculatorConversionDirection
    }
}
