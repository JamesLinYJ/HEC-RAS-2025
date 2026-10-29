import Combine
import Foundation
import RASWorkspaceCore

enum VectorType: String, Sendable { case point = "Point", segment = "Segment", line = "Line", polygon = "Polygon", complexPolygon = "ComplexPolygon", text = "Text" }
typealias VectorSymbologyStyle = VectorStyleValues
typealias VectorCondition = VectorStyleRule
typealias VectorStyleProperty = VectorStyleField

extension VectorStyleField {
    var title: String {
        switch self {
        case .penColor: "Pen Color"
        case .penWidth: "Line Width"
        case .fillColor: "Fill Color"
        case .pointSize: "Point Size"
        }
    }
}

enum VectorAttributeColumnKind: String, Codable, CaseIterable, Sendable {
    case string
    case int32
    case int64
    case float32
    case float64
    case unsupported

    var supportsConditions: Bool { self != .unsupported }
    var isNumeric: Bool { self == .int32 || self == .int64 || self == .float32 || self == .float64 }
}

enum VectorStyleNumberField: String, Hashable, Sendable {
    case penWidth
    case pointSize
    case haloThickness
}

struct VectorStyleNumberDraftKey: Hashable, Sendable {
    let optionID: String
    let field: VectorStyleNumberField
}

struct VectorAttributeColumn: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let kind: VectorAttributeColumnKind
    /// Retained for older callers while unknown non-string source types remain
    /// unsupported instead of being guessed as numeric.
    var isString: Bool { kind == .string }

    init(id: String, name: String, kind: VectorAttributeColumnKind, sourceTypeName: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.sourceTypeName = sourceTypeName
    }

    init(id: String, name: String, isString: Bool) {
        self.init(id: id, name: name, kind: isString ? .string : .unsupported)
    }

    /// Exact original runtime type text is useful when reporting a source type
    /// the native editor cannot safely compare.
    let sourceTypeName: String?
}

struct VectorStyleOption: Identifiable, Sendable {
    let id: String
    let name: String
    var nameIsUserData = false
    var layerName: String? = nil
    let type: VectorType
    var style: VectorSymbologyStyle
    let defaultStyle: VectorSymbologyStyle
    let columns: [VectorAttributeColumn]
    var conditions: [VectorStyleProperty: [VectorCondition]] = [:]
    var conditionsEnabled = true
    var conditionCapability: VectorStyleConditionCapability? = nil
    var conditionCapabilityReason: String? = nil
    var showLightDarkPreview = true
    // The source adapter runs the original full ResetSymbologyToDefault
    // before applying edited presentation fields; hidden style data is retained.
    var resetRequested = false
    var properties: [VectorStyleProperty] {
        if let definition = SourceVectorStyleCatalog.definition(for: id) {
            return definition.supportedFields
        }
        // This is the union of the original ShowLineEditor,
        // ShowPolygonEditor, ShowPointEditor, and ShowTextEditor surfaces,
        // with GetPropertyLabels determining fields for each geometry type.
        return switch type {
        case .point: [.penColor, .penWidth, .fillColor, .pointSize]
        case .line: [.penColor, .penWidth]
        case .polygon: [.penColor, .penWidth, .fillColor]
        default: []
        }
    }
    var effectiveConditionCapability: VectorStyleConditionCapability {
        conditionCapability
            ?? SourceVectorStyleCatalog.definition(for: id)?.conditionCapability
            ?? .attributeTable
    }
    var supportsAttributeConditions: Bool {
        conditionsEnabled && conditionCapabilityReason == nil && effectiveConditionCapability == .attributeTable
    }
    func operators(for column: String) -> [String] {
        guard let kind = columns.first(where: { $0.name == column })?.kind else { return [] }
        return switch kind {
        case .string: ["equals", "not equals", "contains", "starts with", "ends with"]
        case .int32, .int64, .float32, .float64: ["==", "!=", ">", ">=", "<", "<="]
        case .unsupported: []
        }
    }
}
struct VectorPlotOption: Identifiable, Sendable {
    let id: String
    let title: String
    let isBoolean: Bool
    var value: String
    let choices: [EditorChoice]
    let isEnabled: Bool
    var description: String? = nil
}
struct VectorSymbologySnapshot: Sendable {
    let options: [VectorStyleOption]
    let additionalOptions: [VectorPlotOption]
    let canEdit: Bool
}
enum VectorSymbologyScope: Hashable, Sendable { case layer, global }
struct VectorSymbologyContext: Hashable, Sendable {
    let projectSessionID: UUID
    let mapID: UUID
    let assetID: String?
    let layerID: String?
    let visualizationRevision: String?
    let visualNode: VectorVisualNodeIdentity?
    let specializedNode: SpecializedVectorVisualNodeIdentity?
    var scope: VectorSymbologyScope

    init(
        projectSessionID: UUID,
        mapID: UUID,
        assetID: String?,
        layerID: String? = nil,
        visualizationRevision: String? = nil,
        visualNode: VectorVisualNodeIdentity? = nil,
        specializedNode: SpecializedVectorVisualNodeIdentity? = nil,
        scope: VectorSymbologyScope = .layer
    ) {
        self.projectSessionID = projectSessionID
        self.mapID = mapID
        self.assetID = assetID
        self.layerID = layerID
        self.visualizationRevision = visualizationRevision
        self.visualNode = visualNode
        self.specializedNode = specializedNode
        self.scope = scope
    }

    /// Used only to reconcile a selected tree layer after the same owner has
    /// received a newer `.vis` revision. Apply still requires exact equality.
    func hasSameVisualTarget(as other: VectorSymbologyContext) -> Bool {
        projectSessionID == other.projectSessionID
            && mapID == other.mapID
            && assetID == other.assetID
            && layerID == other.layerID
            && visualNode == other.visualNode
            && specializedNode == other.specializedNode
            && scope == other.scope
    }
}

enum VectorSymbologyValidation {
    static let invalidStyle = "Vector style contains an invalid color or non-finite value."
    static let invalidNumberDraft = "Enter a valid number within the supported range."
    static let invalidColumn = "Choose a supported attribute column and operator before applying."
    static let invalidThreshold = "The conditional rule threshold does not match the selected column type."
    static let invalidResult = "The conditional rule result does not match the property type."

    static func issueKey(options: [VectorStyleOption], scope: VectorSymbologyScope) -> String? {
        for option in options where option.style.validatedForPersistence() == nil {
            return invalidStyle
        }
        for option in options where Int32(exactly: option.style.pointSize) == nil {
            return invalidNumberDraft
        }
        guard scope == .layer else { return nil }
        for option in options where option.supportsAttributeConditions {
            for property in option.properties {
                for rule in option.conditions[property] ?? [] {
                    guard !rule.column.isEmpty, !rule.threshold.isEmpty, !rule.resultValue.isEmpty else { continue }
                    guard let column = option.columns.first(where: { $0.name == rule.column }),
                          column.kind.supportsConditions,
                          option.operators(for: column.name).contains(rule.comparison) else {
                        return invalidColumn
                    }
                    guard threshold(rule.threshold, matches: column.kind) else { return invalidThreshold }
                    if property == .penWidth, Double(rule.resultValue.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
                        return invalidResult
                    }
                    if property == .pointSize, Int32(rule.resultValue.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
                        return invalidResult
                    }
                }
            }
        }
        return nil
    }

    private static func threshold(_ value: String, matches kind: VectorAttributeColumnKind) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return switch kind {
        case .string: true
        case .int32: Int32(value) != nil
        case .int64: Int64(value) != nil
        case .float32: Float(value) != nil
        case .float64: Double(value) != nil
        case .unsupported: false
        }
    }
}
@MainActor
protocol VectorSymbologyProvider {
    func snapshot(_ context: VectorSymbologyContext) async throws -> VectorSymbologySnapshot?
    func apply(options: [VectorStyleOption], additionalOptions: [VectorPlotOption], context: VectorSymbologyContext) async throws -> MapUpdate
    func resetAllDefaults(context: VectorSymbologyContext) async throws -> VectorSymbologySnapshot
}
extension VectorSymbologyProvider {
    func resetAllDefaults(context: VectorSymbologyContext) async throws -> VectorSymbologySnapshot { throw CocoaError(.featureUnsupported) }
}
@MainActor
final class VectorSymbologySession: ObservableObject {
    @Published private(set) var options: [VectorStyleOption] = []
    @Published private(set) var additionalOptions: [VectorPlotOption] = []
    @Published private(set) var canEdit = false
    @Published private(set) var busy = false
    @Published private(set) var numericInputDrafts: [VectorStyleNumberDraftKey: String] = [:]
    @Published var error: String?
    private var revision = 0
    private var context: VectorSymbologyContext?
    private var loadToken = 0
    private var liveProvider: (any VectorSymbologyProvider)?
    private struct InFlightApply {
        let id: UUID
        let context: VectorSymbologyContext
    }
    private var inFlightApply: InFlightApply?
    private var liveTask: Task<Void, Never>?
    private var pendingLiveEdit = false
    private var pendingResetAll = false
    private var resetTokens: [String: Int] = [:]
    var didUpdate: ((VectorSymbologyContext, MapUpdate) -> Void)?
    private var hasInvalidNumericInputDraft: Bool {
        numericInputDrafts.contains { !Self.isValidNumericInput($0.value, field: $0.key.field) }
    }
    var hasPendingGlobalChanges: Bool {
        liveTask != nil || pendingLiveEdit || pendingResetAll || (context?.scope == .global && hasInvalidNumericInputDraft)
    }
    var validationIssue: String? {
        if hasInvalidNumericInputDraft {
            return VectorSymbologyValidation.invalidNumberDraft
        }
        return VectorSymbologyValidation.issueKey(options: options, scope: context?.scope ?? .layer)
    }
    func load(context: VectorSymbologyContext, provider: (any VectorSymbologyProvider)?) async {
        if let inFlightApply, inFlightApply.context.hasSameVisualTarget(as: context) {
            // A successful local Apply may publish a new .vis revision before
            // its provider call returns. Keep the submitted candidate alive;
            // the provider's response decides whether that exact request was
            // accepted. If it fails, the candidate remains editable against
            // this latest owner revision.
            self.context = context
            liveProvider = provider
            return
        }
        let preserveDrafts = self.context?.hasSameVisualTarget(as: context) == true
        invalidate(preservingNumericInputDrafts: preserveDrafts)
        let captured = revision; self.context = context; liveProvider = provider
        options = []; additionalOptions = []; canEdit = false; busy = false; error = nil
        guard let provider else { return }; busy = true
        var installedSnapshot = false
        do {
            let value = try await provider.snapshot(context)
            guard captured == revision, !Task.isCancelled else { return }
            if let value {
                options = value.options; additionalOptions = value.additionalOptions; canEdit = value.canEdit
                installedSnapshot = true
            }
        } catch { if captured == revision, !Task.isCancelled { self.error = error.localizedDescription } }
        if captured == revision { busy = false }
        if installedSnapshot, captured == revision { reapplyValidNumericDrafts() }
    }
    func edit(_ id: String, _ action: (inout VectorStyleOption) -> Void) {
        guard canEdit, !busy, let index = options.firstIndex(where: { $0.id == id }) else { return }
        action(&options[index]); revision += 1; error = nil; queueGlobalEdit()
    }
    func moveCondition(optionID: String, property: VectorStyleProperty, conditionID: UUID, offset: Int) {
        guard offset != 0 else { return }
        edit(optionID) { option in
            guard var rules = option.conditions[property],
                  let index = rules.firstIndex(where: { $0.id == conditionID }) else { return }
            let destination = index + offset
            guard rules.indices.contains(destination) else { return }
            rules.swapAt(index, destination)
            option.conditions[property] = rules
        }
    }
    // Source ResetSymbologyToDefault resets the style and retains conditions.
    func reset(_ id: String) {
        guard canEdit, !busy else { return }
        numericInputDrafts = numericInputDrafts.filter { $0.key.optionID != id }
        resetTokens[id, default: 0] += 1
        edit(id) { $0.style = $0.defaultStyle; $0.resetRequested = true }
    }
    func numericInputText(optionID: String, field: VectorStyleNumberField) -> String {
        let key = VectorStyleNumberDraftKey(optionID: optionID, field: field)
        if let draft = numericInputDrafts[key] { return draft }
        guard let style = options.first(where: { $0.id == optionID })?.style else { return "" }
        return switch field {
        case .penWidth: Self.formatG8(style.penWidth)
        case .pointSize: String(style.pointSize)
        case .haloThickness: Self.formatG8(style.haloThickness)
        }
    }
    func setNumericInputText(_ text: String, optionID: String, field: VectorStyleNumberField) {
        guard canEdit, !busy, options.contains(where: { $0.id == optionID }) else { return }
        let key = VectorStyleNumberDraftKey(optionID: optionID, field: field)
        numericInputDrafts[key] = text
        switch field {
        case .penWidth, .haloThickness:
            guard let value = Self.parseFiniteDecimal(text) else { return }
            edit(optionID) { option in
                switch field {
                case .penWidth: option.style.penWidth = value
                case .haloThickness: option.style.haloThickness = value
                case .pointSize: break
                }
            }
        case .pointSize:
            guard let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            edit(optionID) { $0.style.pointSize = Int(value) }
        }
    }
    func numericInputIsInvalid(optionID: String, field: VectorStyleNumberField) -> Bool {
        let key = VectorStyleNumberDraftKey(optionID: optionID, field: field)
        guard let draft = numericInputDrafts[key] else { return false }
        return !Self.isValidNumericInput(draft, field: field)
    }
    private static func isValidNumericInput(_ text: String, field: VectorStyleNumberField) -> Bool {
        switch field {
        case .pointSize:
            Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        case .penWidth, .haloThickness:
            parseFiniteDecimal(text) != nil
        }
    }
    private static func parseFiniteDecimal(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let separator = Locale.current.decimalSeparator ?? "."
        var canonical = trimmed
        if separator != "." {
            guard !(canonical.contains(separator) && canonical.contains(".")) else { return nil }
            canonical = canonical.replacingOccurrences(of: separator, with: ".")
        }
        guard canonical.range(of: #"^[+-]?(?:(?:[0-9]+(?:\.[0-9]*)?)|(?:\.[0-9]+))(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil,
              let value = Double(canonical), value.isFinite else { return nil }
        return value
    }
    private static func formatG8(_ value: Double) -> String {
        String(format: "%.*g", locale: Locale.current, arguments: [8, value])
    }
    private func reapplyValidNumericDrafts() {
        for (key, text) in Array(numericInputDrafts) where Self.isValidNumericInput(text, field: key.field) {
            guard options.contains(where: { $0.id == key.optionID }) else { continue }
            switch key.field {
            case .pointSize:
                guard let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
                edit(key.optionID) { $0.style.pointSize = Int(value) }
            case .penWidth, .haloThickness:
                guard let value = Self.parseFiniteDecimal(text) else { continue }
                edit(key.optionID) { option in
                    if key.field == .penWidth { option.style.penWidth = value }
                    else { option.style.haloThickness = value }
                }
            }
        }
    }
    func setAdditional(_ id: String, value: String) {
        guard canEdit, !busy, let index = additionalOptions.firstIndex(where: { $0.id == id && $0.isEnabled }) else { return }
        additionalOptions[index].value = value; revision += 1; error = nil; queueGlobalEdit()
    }
    func apply(provider: (any VectorSymbologyProvider)?) async -> MapUpdate? {
        guard canEdit, !busy, let provider, let context else { return nil }
        if let issue = validationIssue {
            error = L10n.text(issue)
            return nil
        }
        let captured = revision
        let requestID = UUID()
        inFlightApply = InFlightApply(id: requestID, context: context)
        busy = true; error = nil
        defer {
            if inFlightApply?.id == requestID {
                inFlightApply = nil
                if captured == revision, self.context?.hasSameVisualTarget(as: context) == true {
                    busy = false
                }
            }
        }
        do {
            let update = try await provider.apply(options: options, additionalOptions: additionalOptions, context: context)
            guard captured == revision, self.context?.hasSameVisualTarget(as: context) == true, !Task.isCancelled else { return nil }
            return update
        } catch {
            if captured == revision, self.context?.hasSameVisualTarget(as: context) == true, !Task.isCancelled {
                self.error = error.localizedDescription
            }
            return nil
        }
    }
    func resetAllGlobalDefaults() {
        guard context?.scope == .global, canEdit, !busy else { return }
        numericInputDrafts = [:]
        for index in options.indices {
            options[index].style = options[index].defaultStyle; options[index].resetRequested = true
            resetTokens[options[index].id, default: 0] += 1
        }
        revision += 1; pendingResetAll = true; queueGlobalEdit()
    }
    func flushGlobalChanges(retry: Bool = true) async -> Bool {
        if retry && (pendingLiveEdit || pendingResetAll) { startGlobalQueue() }
        while let task = liveTask { await task.value }
        return error == nil && !pendingLiveEdit && !pendingResetAll && !hasInvalidNumericInputDraft
    }
    func invalidate() {
        invalidate(preservingNumericInputDrafts: false)
    }
    private func invalidate(preservingNumericInputDrafts: Bool) {
        revision += 1; loadToken += 1; busy = false
        if !preservingNumericInputDrafts { numericInputDrafts = [:] }
        liveTask?.cancel(); liveTask = nil; pendingLiveEdit = false; pendingResetAll = false; resetTokens = [:]
        context = nil; liveProvider = nil; inFlightApply = nil
    }
    private func queueGlobalEdit() {
        guard context?.scope == .global, liveProvider != nil else { return }
        pendingLiveEdit = true; startGlobalQueue()
    }
    private func startGlobalQueue() {
        guard liveTask == nil, let context, context.scope == .global, let provider = liveProvider else { return }
        if let issue = validationIssue {
            error = L10n.text(issue)
            return
        }
        let token = loadToken; error = nil
        liveTask = Task {
            defer { if token == loadToken { liveTask = nil } }
            while (pendingLiveEdit || pendingResetAll), token == loadToken, !Task.isCancelled {
                guard self.context == context else { return }
                let capturedOptions = options, capturedAdditional = additionalOptions
                let capturedRevision = revision
                let capturedResetTokens = resetTokens
                let resetAll = pendingResetAll
                pendingLiveEdit = false; pendingResetAll = false
                do {
                    if resetAll { _ = try await provider.resetAllDefaults(context: context) }
                    guard token == loadToken, self.context == context, !Task.isCancelled else { return }
                    let update = try await provider.apply(options: capturedOptions, additionalOptions: capturedAdditional, context: context)
                    guard token == loadToken, self.context == context, !Task.isCancelled else { return }
                    guard capturedRevision == revision else { continue }
                    for index in options.indices where capturedOptions.contains(where: { $0.id == options[index].id && $0.resetRequested }) {
                        if resetTokens[options[index].id] == capturedResetTokens[options[index].id] { options[index].resetRequested = false }
                    }
                    didUpdate?(context, update)
                } catch {
                    guard token == loadToken, self.context == context, !Task.isCancelled else { return }
                    self.error = error.localizedDescription
                    pendingLiveEdit = true; pendingResetAll = pendingResetAll || resetAll
                    return
                }
            }
        }
    }
}
