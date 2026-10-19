import Foundation

struct GeometryTopologyArcPointsRequest: Encodable, Sendable {
    let model: GeometryTopologyModelRequest
    let revision: String
    let draftState: String
    let arcFID: Int
}

struct GeometryTopologyArcPointsSnapshot: Decodable, Sendable {
    let revision: String
    let draftIdentity: String
    let arcFID: Int
    let rows: [GeometryTopologyArcPoint]
}

struct GeometryTopologyArcPoint: Codable, Hashable, Identifiable, Sendable {
    let rowIndex: Int
    let pointKind: String
    let internalPointIndex: Int?
    let endpointNodeIndex: Int?
    let x: Double
    let y: Double

    var id: Int { rowIndex }
}

struct GeometryTopologyRecipeRequest: Encodable, Sendable {
    let model: GeometryTopologyModelRequest
    let revision: String
    let draftState: String
    let controlPointFIDs: [Int]
    let recipeText: String?
}

struct GeometryTopologyRecipeSnapshot: Decodable, Sendable {
    let revision: String
    let draftIdentity: String
    let controlPointFIDs: [Int]
    let hasSelection: Bool
    let hasMismatch: Bool
    let commonRecipe: String?
    let rawText: String
    let isValid: Bool
    let parseIssue: String?
    let steps: [GeometryTopologyRecipeStep]
    let stepSchema: [GeometryTopologyRecipeStepSchema]
    let selectedRecipes: [GeometryTopologyControlPointRecipe]
    let selectedPatchTypes: [String]?

    init(revision: String, draftIdentity: String, controlPointFIDs: [Int], hasSelection: Bool,
         hasMismatch: Bool, commonRecipe: String?, rawText: String, isValid: Bool, parseIssue: String?,
         steps: [GeometryTopologyRecipeStep], stepSchema: [GeometryTopologyRecipeStepSchema],
         selectedRecipes: [GeometryTopologyControlPointRecipe], selectedPatchTypes: [String]? = nil) {
        self.revision = revision
        self.draftIdentity = draftIdentity
        self.controlPointFIDs = controlPointFIDs
        self.hasSelection = hasSelection
        self.hasMismatch = hasMismatch
        self.commonRecipe = commonRecipe
        self.rawText = rawText
        self.isValid = isValid
        self.parseIssue = parseIssue
        self.steps = steps
        self.stepSchema = stepSchema
        self.selectedRecipes = selectedRecipes
        self.selectedPatchTypes = selectedPatchTypes
    }

    private enum CodingKeys: String, CodingKey {
        case revision, draftIdentity, controlPointFIDs, hasSelection, hasMismatch, commonRecipe
        case rawText, isValid, parseIssue, steps, stepSchema, selectedRecipes, selectedPatchTypes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(String.self, forKey: .revision)
        draftIdentity = try container.decode(String.self, forKey: .draftIdentity)
        controlPointFIDs = try container.decode([Int].self, forKey: .controlPointFIDs)
        hasSelection = try container.decode(Bool.self, forKey: .hasSelection)
        hasMismatch = try container.decode(Bool.self, forKey: .hasMismatch)
        commonRecipe = try container.decodeIfPresent(String.self, forKey: .commonRecipe)
        rawText = try container.decode(String.self, forKey: .rawText)
        isValid = try container.decode(Bool.self, forKey: .isValid)
        parseIssue = try container.decodeIfPresent(String.self, forKey: .parseIssue)
        steps = try container.decode([GeometryTopologyRecipeStep].self, forKey: .steps)
        stepSchema = try container.decode([GeometryTopologyRecipeStepSchema].self, forKey: .stepSchema)
        selectedRecipes = try container.decode([GeometryTopologyControlPointRecipe].self, forKey: .selectedRecipes)
        selectedPatchTypes = try container.decodeIfPresent([String].self, forKey: .selectedPatchTypes)
    }
}

struct GeometryTopologyControlPointRecipe: Decodable, Equatable, Sendable {
    let fid: Int
    let recipe: String
}

struct GeometryTopologyRecipeStep: Decodable, Equatable, Sendable {
    let name: String
    let parameters: [String: String]
}

struct GeometryTopologyRecipeStepSchema: Decodable, Equatable, Sendable {
    let name: String
    let aliases: [String]
    let parameters: [GeometryTopologyRecipeParameter]
}

struct GeometryTopologyRecipeParameter: Decodable, Equatable, Sendable {
    let name: String
    let sourceType: String
    let defaultValue: String
}

/// Presentation-only recipe state. Raw invalid input is kept separately from
/// the backend-owned opaque topology draft and never enters mutation history
/// until `applyRecipe` succeeds.
struct GeometryTopologyRecipeEditorState: Sendable {
    var controlPointFIDs: [Int]
    var sourceRevision: String
    var draftIdentity: String
    var rawText: String
    var baselineRawText: String
    var lastValidText: String?
    var inspection: GeometryTopologyRecipeSnapshot?
    var isInspecting = false
    var error: String?
    var isPending = false
}

enum GeometryTopologyCoordinateAxis: String, Codable, CaseIterable, Sendable {
    case x = "X"
    case y = "Y"
}

struct GeometryTopologyArcPointInputDraft: Equatable, Identifiable, Sendable {
    let sourceRevision: String
    let draftIdentity: String
    let arcFID: Int
    let rowIndex: Int
    let pointKind: String
    let internalPointIndex: Int?
    let endpointNodeIndex: Int?
    let axis: GeometryTopologyCoordinateAxis
    var rawText: String

    var id: String {
        "\(sourceRevision)|\(draftIdentity)|\(arcFID)|\(rowIndex)|\(pointKind)|\(axis.rawValue)"
    }
}

enum GeometryTopologyTagFilterClauseType: String, Codable, Sendable {
    case tag = "Tag"
    case property = "Property"
}

enum GeometryTopologyTagFilterOperator: String, Codable, CaseIterable, Sendable {
    case isNotBlank = "IsNotBlank"
    case isBlank = "IsBlank"
    case equals = "Equals"
    case notEquals = "NotEquals"
    case contains = "Contains"
    case doesNotContain = "DoesNotContain"
    case lessThan = "LessThan"
    case atMost = "AtMost"
    case greaterThan = "GreaterThan"
    case atLeast = "AtLeast"
}

struct GeometryTopologyTagFilterClause: Codable, Hashable, Identifiable, Sendable {
    let type: GeometryTopologyTagFilterClauseType
    let tagDefinitionID: String?
    let propertyColumnID: String?
    let filterOperator: GeometryTopologyTagFilterOperator
    let value: String?

    var id: String {
        [type.rawValue, tagDefinitionID ?? "", propertyColumnID ?? "",
         filterOperator.rawValue, value ?? ""].joined(separator: "\u{1f}")
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case tagDefinitionID
        case propertyColumnID
        case filterOperator = "operator"
        case value
    }

    static func tag(definitionID: String, operator filterOperator: GeometryTopologyTagFilterOperator,
                    value: String? = nil) -> Self {
        Self(type: .tag, tagDefinitionID: definitionID, propertyColumnID: nil,
             filterOperator: filterOperator, value: value)
    }

    static func property(columnID: String, operator filterOperator: GeometryTopologyTagFilterOperator,
                         value: String? = nil) -> Self {
        Self(type: .property, tagDefinitionID: nil, propertyColumnID: columnID,
             filterOperator: filterOperator, value: value)
    }

    var hasValidIdentityShape: Bool {
        switch type {
        case .tag:
            tagDefinitionID?.isEmpty == false && propertyColumnID == nil
        case .property:
            propertyColumnID?.isEmpty == false && tagDefinitionID == nil
        }
    }
}

struct GeometryTopologyTagFilterQuery: Codable, Hashable, Sendable {
    /// The wire contract is exactly `arc` or `region`; region resolves to the
    /// retained ControlPoint table in the backend.
    let featureKind: String
    var clauses: [GeometryTopologyTagFilterClause]

    init(featureKind: String, clauses: [GeometryTopologyTagFilterClause] = []) {
        self.featureKind = featureKind == "controlPoint" ? "region" : featureKind
        self.clauses = clauses
    }

    var hasValidShape: Bool {
        (featureKind == "arc" || featureKind == "region")
            && clauses.allSatisfy(\.hasValidIdentityShape)
    }
}

struct GeometryTopologyFilterRequest: Encodable, Sendable {
    let model: GeometryTopologyModelRequest
    let revision: String
    let draftState: String
    let featureKind: String
    let clauses: [GeometryTopologyTagFilterClause]
}

struct GeometryTopologyFilterSnapshot: Decodable, Sendable {
    let revision: String
    let draftIdentity: String
    let featureKind: String
    let matchedFeatureIDs: [Int]
    let propertyDescriptors: [GeometryTopologyPropertyDescriptor]
    let tagDefinitions: [GeometryTopologyTagDefinition]
}

struct GeometryTopologyPropertyDescriptor: Decodable, Identifiable, Sendable {
    let name: String
    let columnName: String
    let sourceType: String
    /// Present when the Host knows the retained CLR type exactly. Older
    /// snapshots omit this key, so callers must not infer enums from names.
    var isEnum: Bool? = nil

    var id: String { columnName }
}
