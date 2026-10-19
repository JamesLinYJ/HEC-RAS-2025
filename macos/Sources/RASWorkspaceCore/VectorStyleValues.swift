import Foundation

/// Presentation values shared by global preferences and per-context `.vis`
/// adapters. Colors use the source's ARGB byte order (`#AARRGGBB`).
public struct VectorStyleValues: Codable, Equatable, Sendable {
    public var penColor: String
    public var penWidth: Double
    public var fillColor: String
    public var pointSize: Int
    public var haloColor: String
    public var haloThickness: Double
    public var textEmphasis: Int

    public init(
        penColor: String = "#FF000000",
        penWidth: Double = 1,
        fillColor: String = "#800000FF",
        pointSize: Int = 3,
        haloColor: String = "#00000000",
        haloThickness: Double = 0,
        textEmphasis: Int = 0
    ) {
        self.penColor = penColor
        self.penWidth = penWidth
        self.fillColor = fillColor
        self.pointSize = pointSize
        self.haloColor = haloColor
        self.haloThickness = haloThickness
        self.textEmphasis = textEmphasis
    }

    /// Returns canonical source-compatible values, or nil for malformed
    /// colors, non-finite measurements, or integers outside the retained C#
    /// Int32 storage contract. Zero and negative source values remain valid.
    public func validatedForPersistence() -> VectorStyleValues? {
        guard penWidth.isFinite, haloThickness.isFinite,
              Int32(exactly: pointSize) != nil, Int32(exactly: textEmphasis) != nil,
              let penColor = Self.canonicalARGB(penColor),
              let fillColor = Self.canonicalARGB(fillColor),
              let haloColor = Self.canonicalARGB(haloColor) else { return nil }
        return VectorStyleValues(
            penColor: penColor,
            penWidth: penWidth,
            fillColor: fillColor,
            pointSize: pointSize,
            haloColor: haloColor,
            haloThickness: haloThickness,
            textEmphasis: textEmphasis
        )
    }

    private static func canonicalARGB(_ value: String) -> String? {
        guard value.count == 9, value.first == "#" else { return nil }
        let bytes = value.dropFirst()
        guard bytes.unicodeScalars.allSatisfy({
            (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
        }) else { return nil }
        return "#" + bytes.uppercased()
    }
}

/// The four property condition groups written by the retained visual context.
public enum VectorStyleField: String, Codable, CaseIterable, Equatable, Sendable {
    case penColor = "PenColor"
    case penWidth = "PenWidth"
    case fillColor = "FillColor"
    case pointSize = "PointSize"
}

/// Ordered conditional rule data. Evaluation and attribute table row binding
/// remain the responsibility of the source-backed visual-context provider.
public struct VectorStyleRule: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var column: String
    public var comparison: String
    public var threshold: String
    public var resultValue: String

    public init(
        id: UUID = UUID(),
        column: String = "",
        comparison: String = "==",
        threshold: String = "",
        resultValue: String = ""
    ) {
        self.id = id
        self.column = column
        self.comparison = comparison
        self.threshold = threshold
        self.resultValue = resultValue
    }
}

/// Capability of a source definition's conditional renderer. Attribute-table
/// rules still require a matching table to be supplied by the owning context.
public enum VectorStyleConditionCapability: String, Codable, Equatable, Sendable {
    case attributeTable
    case topologyNodeState
    case globalOnly
}

/// One source declaration for a definition ID. Some IDs have more than one
/// declaration in the retained assemblies; variants preserve that provenance.
public struct VectorStyleDefinitionVariant: Codable, Equatable, Sendable {
    public let sourceContext: String
    public let name: String
    public let layerName: String
    public let type: String
    public let defaultStyle: VectorStyleValues
    public let supportedFields: [VectorStyleField]
    public let conditionCapability: VectorStyleConditionCapability

    public init(
        sourceContext: String,
        name: String,
        layerName: String,
        type: String,
        defaultStyle: VectorStyleValues,
        supportedFields: [VectorStyleField],
        conditionCapability: VectorStyleConditionCapability
    ) {
        self.sourceContext = sourceContext
        self.name = name
        self.layerName = layerName
        self.type = type
        self.defaultStyle = defaultStyle
        self.supportedFields = supportedFields
        self.conditionCapability = conditionCapability
    }
}

/// A unique persisted definition ID plus all known source declarations.
/// `defaultStyle` and presentation metadata use the first variant in the
/// native deterministic catalog order. The source registry also keeps the
/// first registration by ID, but does not guarantee reflection ordering.
public struct VectorStyleDefinition: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let layerName: String
    public let type: String
    public let defaultStyle: VectorStyleValues
    public let supportedFields: [VectorStyleField]
    public let conditionCapability: VectorStyleConditionCapability
    public let variants: [VectorStyleDefinitionVariant]

    public var conditionsSupported: Bool { conditionCapability == .attributeTable }
    public var hasSpecializedConditionalRendering: Bool { conditionCapability == .topologyNodeState }
    public var textStyleSupported: Bool { type == "Text" }

    public init(id: String, variants: [VectorStyleDefinitionVariant]) {
        precondition(!variants.isEmpty, "A vector style definition requires a source variant.")
        let first = variants[0]
        self.id = id
        self.name = first.name
        self.layerName = first.layerName
        self.type = first.type
        self.defaultStyle = first.defaultStyle
        self.supportedFields = first.supportedFields
        self.conditionCapability = first.conditionCapability
        self.variants = variants
    }
}
