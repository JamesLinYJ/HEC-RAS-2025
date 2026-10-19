import Foundation

enum WilcockBTMMode: String, Codable, Sendable {
    case sbtm = "SBTM"
    case isbtm = "ISBTM"
}

struct WilcockDraft: Codable, Equatable, Sendable {
    var numberCulture: String?
    var btmMode: WilcockBTMMode
    var sbtm: WilcockSBTMInput
    var isbtm: WilcockISBTMInput
    var stab: WilcockSTABInput
    var state: WilcockSTATEInput
    var selectedCaseID: String?
    var selectedPlotIndex: Int

    static let empty = WilcockDraft(
        numberCulture: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
        btmMode: .sbtm,
        sbtm: .init(),
        isbtm: .init(),
        stab: .init(),
        state: .init(),
        selectedCaseID: nil,
        selectedPlotIndex: 0
    )

    mutating func setCell(tableID: String, rowID: String, columnID: String, rawText: String) -> Bool {
        switch tableID {
        case "btm.sbtm.input":
            guard let index = Self.index(rowID, prefix: "grain:") else { return false }
            switch columnID {
            case "grainDiameter": return Self.setOrExtend(&sbtm.grainDiameter, at: index, with: rawText)
            case "surfaceCdf": return Self.setOrExtend(&sbtm.surfaceCdf, at: index, with: rawText)
            default: return false
            }
        case "btm.isbtm.input":
            guard let index = Self.index(rowID, prefix: "grain:") else { return false }
            switch columnID {
            case "grainDiameter": return Self.setOrExtend(&isbtm.grainDiameter, at: index, with: rawText)
            case "transportCdf": return Self.setOrExtend(&isbtm.transportCdf, at: index, with: rawText)
            default: return false
            }
        case "stab.caseInputs":
            guard let index = Self.index(rowID, prefix: "case:") else { return false }
            switch columnID {
            case "waterDischarge": return Self.setOrExtend(&stab.waterDischarges, at: index, with: rawText)
            case "sedimentSupplyRate": return Self.setOrExtend(&stab.sedimentSupplyRates, at: index, with: rawText)
            default: return false
            }
        case "stab.grainSizeDistributions":
            guard let grainIndex = Self.index(rowID, prefix: "grain:") else { return false }
            if columnID == "grainDiameter" {
                return Self.setOrExtend(&stab.grainDiameter, at: grainIndex, with: rawText)
            }
            guard let caseIndex = Self.index(columnID, prefix: "case:") else { return false }
            guard stab.transportGrainSizes.indices.contains(caseIndex) else { return false }
            return Self.setOrExtend(&stab.transportGrainSizes[caseIndex], at: grainIndex, with: rawText)
        case "state.grainDistributions":
            guard let index = Self.index(rowID, prefix: "grain:") else { return false }
            switch columnID {
            case "grainDiameter": return Self.setOrExtend(&state.grainDiameter, at: index, with: rawText)
            case "firstCDF": return Self.setOrExtend(&state.firstTransportCdfGrainSize, at: index, with: rawText)
            case "secondCDF": return Self.setOrExtend(&state.secondTransportCdfGrainSize, at: index, with: rawText)
            default: return false
            }
        case "state.transportRates":
            guard columnID == "transportRate", let index = Self.index(rowID, prefix: "value:") else { return false }
            return Self.setOrExtend(&state.transportRates, at: index, with: rawText)
        case "state.slopes":
            guard columnID == "slope", let index = Self.index(rowID, prefix: "value:") else { return false }
            return Self.setOrExtend(&state.slopes, at: index, with: rawText)
        default:
            return false
        }
    }

    /// Mutates exactly one source array. Retained BindableArrayWrapper inputs are
    /// variable-sized; calculator validation, not this editor, owns length rules.
    mutating func appendInputCell(tableID: String, columnID: String, rawText: String = "0") -> Bool {
        switch tableID {
        case "btm.sbtm.input":
            switch columnID {
            case "grainDiameter": sbtm.grainDiameter.append(rawText)
            case "surfaceCdf": sbtm.surfaceCdf.append(rawText)
            default: return false
            }
        case "btm.isbtm.input":
            switch columnID {
            case "grainDiameter": isbtm.grainDiameter.append(rawText)
            case "transportCdf": isbtm.transportCdf.append(rawText)
            default: return false
            }
        case "stab.grainSizeDistributions":
            if columnID == "grainDiameter" {
                stab.grainDiameter.append(rawText)
            } else if let index = Self.index(columnID, prefix: "case:"), stab.transportGrainSizes.indices.contains(index) {
                stab.transportGrainSizes[index].append(rawText)
            } else {
                return false
            }
        case "state.grainDistributions":
            switch columnID {
            case "grainDiameter": state.grainDiameter.append(rawText)
            case "firstCDF": state.firstTransportCdfGrainSize.append(rawText)
            case "secondCDF": state.secondTransportCdfGrainSize.append(rawText)
            default: return false
            }
        case "state.transportRates":
            guard columnID == "transportRate" else { return false }
            state.transportRates.append(rawText)
        case "state.slopes":
            guard columnID == "slope" else { return false }
            state.slopes.append(rawText)
        default:
            // STAB cases are a retained compound action; don't desynchronize their arrays.
            return false
        }
        return true
    }

    mutating func removeInputCell(tableID: String, rowID: String, columnID: String) -> Bool {
        switch tableID {
        case "btm.sbtm.input":
            guard let index = Self.index(rowID, prefix: "grain:") else { return false }
            switch columnID {
            case "grainDiameter": return Self.remove(&sbtm.grainDiameter, at: index)
            case "surfaceCdf": return Self.remove(&sbtm.surfaceCdf, at: index)
            default: return false
            }
        case "btm.isbtm.input":
            guard let index = Self.index(rowID, prefix: "grain:") else { return false }
            switch columnID {
            case "grainDiameter": return Self.remove(&isbtm.grainDiameter, at: index)
            case "transportCdf": return Self.remove(&isbtm.transportCdf, at: index)
            default: return false
            }
        case "stab.grainSizeDistributions":
            guard let index = Self.index(rowID, prefix: "grain:") else { return false }
            if columnID == "grainDiameter" { return Self.remove(&stab.grainDiameter, at: index) }
            guard let caseIndex = Self.index(columnID, prefix: "case:"), stab.transportGrainSizes.indices.contains(caseIndex) else { return false }
            return Self.remove(&stab.transportGrainSizes[caseIndex], at: index)
        case "state.grainDistributions":
            guard let index = Self.index(rowID, prefix: "grain:") else { return false }
            switch columnID {
            case "grainDiameter": return Self.remove(&state.grainDiameter, at: index)
            case "firstCDF": return Self.remove(&state.firstTransportCdfGrainSize, at: index)
            case "secondCDF": return Self.remove(&state.secondTransportCdfGrainSize, at: index)
            default: return false
            }
        case "state.transportRates":
            guard columnID == "transportRate", let index = Self.index(rowID, prefix: "value:") else { return false }
            return Self.remove(&state.transportRates, at: index)
        case "state.slopes":
            guard columnID == "slope", let index = Self.index(rowID, prefix: "value:") else { return false }
            return Self.remove(&state.slopes, at: index)
        default:
            return false
        }
    }

    func inputRowCount(for tableID: String) -> Int? {
        switch tableID {
        case "btm.sbtm.input": return max(sbtm.grainDiameter.count, sbtm.surfaceCdf.count)
        case "btm.isbtm.input": return max(isbtm.grainDiameter.count, isbtm.transportCdf.count)
        case "stab.caseInputs": return max(stab.waterDischarges.count, stab.sedimentSupplyRates.count)
        case "stab.grainSizeDistributions": return max(stab.grainDiameter.count, stab.transportGrainSizes.map(\.count).max() ?? 0)
        case "state.grainDistributions": return max(state.grainDiameter.count, max(state.firstTransportCdfGrainSize.count, state.secondTransportCdfGrainSize.count))
        case "state.transportRates": return state.transportRates.count
        case "state.slopes": return state.slopes.count
        default: return nil
        }
    }

    private static func index(_ value: String, prefix: String) -> Int? {
        guard value.hasPrefix(prefix), let index = Int(value.dropFirst(prefix.count)), index >= 0 else { return nil }
        return index
    }

    private static func setOrExtend(_ values: inout [String], at index: Int, with text: String) -> Bool {
        guard index >= 0 else { return false }
        while values.count <= index { values.append("0") }
        values[index] = text
        return true
    }

    private static func remove(_ values: inout [String], at index: Int) -> Bool {
        guard values.indices.contains(index) else { return false }
        values.remove(at: index)
        return true
    }
}

struct WilcockSBTMInput: Codable, Equatable, Sendable {
    var shearVelocity = ""
    var waterDensity = ""
    var sedimentDensity = ""
    var grainDiameter: [String] = []
    var surfaceCdf: [String] = []
}

struct WilcockISBTMInput: Codable, Equatable, Sendable {
    var totalTransportRate = ""
    var grainDiameter: [String] = []
    var transportCdf: [String] = []
}

struct WilcockSTABInput: Codable, Equatable, Sendable {
    var waterDischarges: [String] = []
    var sedimentSupplyRates: [String] = []
    var transportGrainSizes: [[String]] = []
    var bMin = ""
    var bMax = ""
    var z = ""
    var ns = ""
    var nSpec = ""
    var useThresholdSlope = false
    var tcTauStarC = ""
    var tcD50 = ""
    var tcD84 = ""
    var tcM = ""
    var grainDiameter: [String] = []

    enum CodingKeys: String, CodingKey {
        case waterDischarges, sedimentSupplyRates, transportGrainSizes
        case bMin, bMax, z, ns, useThresholdSlope, tcTauStarC, tcD50, tcD84, tcM, grainDiameter
        case nSpec = "nspec"
    }
}

struct WilcockSTATEInput: Codable, Equatable, Sendable {
    var grainDiameter: [String] = []
    var firstTransportCdfGrainSize: [String] = []
    var secondTransportCdfGrainSize: [String] = []
    var transportRates: [String] = []
    var slopes: [String] = []
}

enum WilcockCalculatorSection: String, Codable, Sendable {
    case btm, stab, state
}

enum WilcockTableRole: String, Codable, Sendable {
    case input, output
}

enum WilcockBTMImportPolicy: String, Codable, Sendable {
    case append, replaceExistingCases, unavailable
}

struct WilcockSourceCaseChoice: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var index: Int
    var waterDischarge: String
    var sedimentSupplyRate: String
}

struct WilcockSourceColumn: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var titleKey: String
    var sourceType: String
    var isEditable: Bool
    var caseIndex: Int?
}

struct WilcockSourceRow: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var titleKey: String?
    var caseIndex: Int?
    var cells: [String]
}

struct WilcockSourceTable: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var section: WilcockCalculatorSection
    var role: WilcockTableRole
    var titleKey: String
    var columns: [WilcockSourceColumn]
    var rows: [WilcockSourceRow]
}

struct WilcockChartPoint: Codable, Equatable, Sendable {
    /// `nil` preserves a source non-finite sample as a chart gap instead of
    /// coercing it to zero or joining the samples on either side.
    var x: Double?
    var y: Double?
}

struct WilcockSourceSeries: Codable, Equatable, Sendable, Identifiable {
    var caseIndex: Int?
    var labelKey: String
    var colorARGB: String
    var strokeWidth: Double
    var points: [WilcockChartPoint]

    var id: String { "\(caseIndex.map(String.init) ?? "all")|\(labelKey)" }
}

struct WilcockSourceChart: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var section: WilcockCalculatorSection
    var titleKey: String
    var xAxisKey: String
    var yAxisKey: String
    var series: [WilcockSourceSeries]
}

/// A faithful JSON projection of a retained result object. UI uses `tables`
/// and charts for presentation while keeping the entire source result available.
enum WilcockJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([WilcockJSONValue])
    case object([String: WilcockJSONValue])
    case null

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var object: [String: WilcockJSONValue] = [:]
            for key in keyed.allKeys { object[key.stringValue] = try keyed.decode(WilcockJSONValue.self, forKey: key) }
            self = .object(object)
            return
        }
        if var unkeyed = try? decoder.unkeyedContainer() {
            var array: [WilcockJSONValue] = []
            while !unkeyed.isAtEnd { array.append(try unkeyed.decode(WilcockJSONValue.self)) }
            self = .array(array)
            return
        }
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unsupported Wilcock JSON value.") }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let value): var container = encoder.singleValueContainer(); try container.encode(value)
        case .number(let value): var container = encoder.singleValueContainer(); try container.encode(value)
        case .bool(let value): var container = encoder.singleValueContainer(); try container.encode(value)
        case .array(let values): var container = encoder.unkeyedContainer(); for value in values { try container.encode(value) }
        case .object(let values):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in values { try container.encode(value, forKey: DynamicCodingKey(stringValue: key)!) }
        case .null: var container = encoder.singleValueContainer(); try container.encodeNil()
        }
    }
}

private struct DynamicCodingKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

struct WilcockWorkspaceSnapshot: Codable, Equatable, Sendable {
    var draft: WilcockDraft
    var btmMode: WilcockBTMMode
    var cases: [WilcockSourceCaseChoice]
    var selectedCaseID: String?
    var selectedPlotIndex: Int
    var canAddCase: Bool
    var canRemoveSelectedCase: Bool
    var canImportCase: Bool
    var btmImportPolicy: WilcockBTMImportPolicy
    var importConfirmationRequired: Bool
    var btmImportReasonKey: String?
    var replacedExistingCases: Bool
    var sbtmResults: [String: WilcockJSONValue]?
    var isbtmResults: [String: WilcockJSONValue]?
    var stabResults: [String: WilcockJSONValue]?
    var stateResults: [String: WilcockJSONValue]?
    var tables: [WilcockSourceTable]
    var charts: [WilcockSourceChart]
    var inputIssues: [WilcockInputIssue]
    var sbtmErrorKey: String?
    var isbtmErrorKey: String?
    var stabErrorKey: String?
    var stateErrorKey: String?

    enum CodingKeys: String, CodingKey {
        case draft, btmMode, cases, selectedCaseID, selectedPlotIndex
        case canAddCase, canImportCase, btmImportPolicy, importConfirmationRequired, btmImportReasonKey, replacedExistingCases
        case sbtmResults, isbtmResults, stabResults, stateResults, tables, charts
        case inputIssues, sbtmErrorKey, isbtmErrorKey, stabErrorKey, stateErrorKey
        case canRemoveSelectedCase = "canRemoveCase"
    }
}

struct WilcockInputIssue: Codable, Equatable, Sendable, Identifiable {
    var section: WilcockCalculatorSection
    var path: String
    var messageKey: String
    var id: String { "\(section.rawValue):\(path)" }
}

struct WilcockEvaluateRequest: Codable, Sendable {
    var draft: WilcockDraft
    var action: WilcockAction
    var caseID: String?
    var confirmImport: Bool?
}

enum WilcockAction: String, Codable, Sendable {
    case calculate, addCase, removeCase, importCaseFromBTM
}

struct WilcockSessionCase: Identifiable, Equatable, Sendable {
    let id: String
    let sourceID: String
    let sourceIndex: Int
    let waterDischarge: String
    let sedimentSupplyRate: String
}

extension WilcockWorkspaceSnapshot {
    func validate() throws {
        guard cases.enumerated().allSatisfy({ offset, item in
            item.index == offset && item.id == "case:\(offset)"
        }), Set(cases.map(\.id)).count == cases.count,
              selectedPlotIndex >= 0 && selectedPlotIndex <= 7,
              charts.allSatisfy({ chart in
                  chart.series.allSatisfy { series in
                      series.points.allSatisfy { point in
                          (point.x == nil || point.x?.isFinite == true)
                              && (point.y == nil || point.y?.isFinite == true)
                      }
                  }
              }),
              tables.allSatisfy({ table in
                  Set(table.columns.map(\.id)).count == table.columns.count
                      && Set(table.rows.map(\.id)).count == table.rows.count
                      && table.rows.allSatisfy { $0.cells.count == table.columns.count }
              }),
              inputIssues.allSatisfy({ !$0.path.isEmpty && !$0.messageKey.isEmpty }) else {
            throw WilcockProviderError.invalidResponse
        }
        guard Set(charts.map(\.id)).count == charts.count,
              charts.allSatisfy({ chart in
                  (chart.id == "btm" && chart.section == .btm)
                      || (chart.id == "state" && chart.section == .state)
                      || (chart.id.hasPrefix("stab.") && chart.section == .stab)
              }) else {
            throw WilcockProviderError.invalidResponse
        }
    }
}

enum WilcockProviderError: Error, LocalizedError, Sendable {
    case invalidResponse

    var errorDescription: String? { "The Wilcock calculator returned an invalid source snapshot." }
}
