import Foundation
import RASWorkspaceCore
import CryptoKit

struct GeometryTopologyModelRequest: Codable, Hashable, Sendable {
    let assetPath: String
    let kind: String
    let projectPath: String?
    let projectXml: String?
}

struct GeometryTopologyMutation: Codable, Sendable {
    let operation: String
    let featureKind: String
    let featureIDs: [Int]
    var fieldID: String? = nil
    var value: String? = nil
    var tagName: String? = nil
    var tagType: String? = nil
    var tagValue: String? = nil

    // Optional/defaulted fields keep mutations serialized by earlier app
    // versions decodable while exposing the retained topology tools.
    var applyToSelectedOnly = false
    var factorText: String? = nil
    var arcFeatureIDs: [Int] = []
    var controlPointFeatureIDs: [Int] = []
    var nodeFeatureIDs: [Int] = []
    var recipeText: String? = nil
    var forceSet = false
    var pointKind: String? = nil
    var internalPointIndex: Int? = nil
    var endpointNodeIndex: Int? = nil
    var axis: String? = nil
    var rawValue: String? = nil

    init(operation: String, featureKind: String, featureIDs: [Int], fieldID: String? = nil,
         value: String? = nil, tagName: String? = nil, tagType: String? = nil, tagValue: String? = nil,
         applyToSelectedOnly: Bool = false, factorText: String? = nil,
         arcFeatureIDs: [Int] = [], controlPointFeatureIDs: [Int] = [], nodeFeatureIDs: [Int] = [], recipeText: String? = nil,
         forceSet: Bool = false, pointKind: String? = nil, internalPointIndex: Int? = nil,
         endpointNodeIndex: Int? = nil, axis: String? = nil, rawValue: String? = nil) {
        self.operation = operation
        self.featureKind = featureKind
        self.featureIDs = featureIDs
        self.fieldID = fieldID
        self.value = value
        self.tagName = tagName
        self.tagType = tagType
        self.tagValue = tagValue
        self.applyToSelectedOnly = applyToSelectedOnly
        self.factorText = factorText
        self.arcFeatureIDs = arcFeatureIDs
        self.controlPointFeatureIDs = controlPointFeatureIDs
        self.nodeFeatureIDs = nodeFeatureIDs
        self.recipeText = recipeText
        self.forceSet = forceSet
        self.pointKind = pointKind
        self.internalPointIndex = internalPointIndex
        self.endpointNodeIndex = endpointNodeIndex
        self.axis = axis
        self.rawValue = rawValue
    }

    private enum CodingKeys: String, CodingKey {
        case operation, featureKind, featureIDs, fieldID, value, tagName, tagType, tagValue
        case applyToSelectedOnly, factorText, arcFeatureIDs, controlPointFeatureIDs, nodeFeatureIDs
        case recipeText, forceSet, pointKind, internalPointIndex, endpointNodeIndex, axis, rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operation = try container.decode(String.self, forKey: .operation)
        featureKind = try container.decode(String.self, forKey: .featureKind)
        featureIDs = try container.decode([Int].self, forKey: .featureIDs)
        fieldID = try container.decodeIfPresent(String.self, forKey: .fieldID)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        tagName = try container.decodeIfPresent(String.self, forKey: .tagName)
        tagType = try container.decodeIfPresent(String.self, forKey: .tagType)
        tagValue = try container.decodeIfPresent(String.self, forKey: .tagValue)
        applyToSelectedOnly = try container.decodeIfPresent(Bool.self, forKey: .applyToSelectedOnly) ?? false
        factorText = try container.decodeIfPresent(String.self, forKey: .factorText)
        arcFeatureIDs = try container.decodeIfPresent([Int].self, forKey: .arcFeatureIDs) ?? []
        controlPointFeatureIDs = try container.decodeIfPresent([Int].self, forKey: .controlPointFeatureIDs) ?? []
        nodeFeatureIDs = try container.decodeIfPresent([Int].self, forKey: .nodeFeatureIDs) ?? []
        recipeText = try container.decodeIfPresent(String.self, forKey: .recipeText)
        forceSet = try container.decodeIfPresent(Bool.self, forKey: .forceSet) ?? false
        pointKind = try container.decodeIfPresent(String.self, forKey: .pointKind)
        internalPointIndex = try container.decodeIfPresent(Int.self, forKey: .internalPointIndex)
        endpointNodeIndex = try container.decodeIfPresent(Int.self, forKey: .endpointNodeIndex)
        axis = try container.decodeIfPresent(String.self, forKey: .axis)
        rawValue = try container.decodeIfPresent(String.self, forKey: .rawValue)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operation, forKey: .operation)
        try container.encode(featureKind, forKey: .featureKind)
        try container.encode(featureIDs, forKey: .featureIDs)
        try container.encodeIfPresent(fieldID, forKey: .fieldID)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(tagName, forKey: .tagName)
        try container.encodeIfPresent(tagType, forKey: .tagType)
        try container.encodeIfPresent(tagValue, forKey: .tagValue)
        try container.encode(applyToSelectedOnly, forKey: .applyToSelectedOnly)
        try container.encodeIfPresent(factorText, forKey: .factorText)
        try container.encode(arcFeatureIDs, forKey: .arcFeatureIDs)
        try container.encode(controlPointFeatureIDs, forKey: .controlPointFeatureIDs)
        try container.encode(nodeFeatureIDs, forKey: .nodeFeatureIDs)
        try container.encodeIfPresent(recipeText, forKey: .recipeText)
        try container.encode(forceSet, forKey: .forceSet)
        try container.encodeIfPresent(pointKind, forKey: .pointKind)
        try container.encodeIfPresent(internalPointIndex, forKey: .internalPointIndex)
        try container.encodeIfPresent(endpointNodeIndex, forKey: .endpointNodeIndex)
        try container.encodeIfPresent(axis, forKey: .axis)
        try container.encodeIfPresent(rawValue, forKey: .rawValue)
    }
}

struct GeometryTopologyField: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let sourceType: String
    let choices: [String]
    let readOnly: Bool
}

struct GeometryTopologyColumn: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let sourceType: String
    let readOnly: Bool
    let isTag: Bool
}

struct GeometryTopologyFeatureRow: Codable, Identifiable, Sendable {
    let id: String
    let fid: Int
    let values: [String: String]
    var x: Double? = nil
    var y: Double? = nil
    var startNodeID: Int? = nil
    var endNodeID: Int? = nil
}

struct GeometryTopologyFeatureTable: Codable, Sendable {
    let featureKind: String
    let columns: [GeometryTopologyColumn]
    let editableFields: [GeometryTopologyField]
    let rows: [GeometryTopologyFeatureRow]
}

struct GeometryTopologyCoordinate: Codable, Hashable, Sendable {
    let x: Double
    let y: Double
}

struct GeometryTopologyExtent: Codable, Hashable, Sendable {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
}

struct GeometryTopologyMapFeature: Codable, Identifiable, Sendable {
    let id: String
    let featureKind: String
    let fid: Int?
    let geometryType: String
    let selectionIDs: [String]
    let paths: [[GeometryTopologyCoordinate]]
    var incidentArcs: [GeometryTopologyIncidentArc]? = nil
}

struct GeometryTopologyIncidentArc: Codable, Hashable, Sendable {
    let arcID: Int
    let length: Double
}

struct GeometryTopologyMapData: Codable, Sendable {
    let extent: GeometryTopologyExtent?
    let features: [GeometryTopologyMapFeature]

    static let empty = GeometryTopologyMapData(extent: nil, features: [])
}

/// Ephemeral result of the retained ConceptualMesh topology completion path.
/// The identity hashes the exact UTF-8 bytes of the snapshot's opaque draft
/// state, so callers can reject a completion paired with a different draft.
struct GeometryTopologyCompletionResult: Codable, Hashable, Sendable {
    let sourceRevision: String
    let draftIdentity: String
    let isComplete: Bool
    let messages: [GeometryTopologyCompletionMessage]

    static func draftIdentity(for draftState: String) -> String {
        SHA256.hash(data: Data(draftState.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct GeometryTopologyCompletionMessage: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let code: String
    let severity: String
    let regionCompletionSeverity: String?
    let text: String
    let logData: [GeometryTopologyLogValue]
    let targets: [GeometryTopologyDiagnosticTarget]
}

struct GeometryTopologyLogValue: Codable, Hashable, Sendable {
    let key: String
    let value: String
    let valueType: String
    let integerValue: Int?
}

/// A Host-validated link from one source OperationResult LogData entry to the
/// exact topology table row and map feature(s) that the retained UI associates.
struct GeometryTopologyDiagnosticTarget: Codable, Hashable, Sendable {
    let featureKind: String
    let fid: Int
    let tableRowID: String
    let mapFeatureIDs: [String]

    var tableFeatureKind: String? {
        switch featureKind {
        case "arc": "arc"
        case "node": "node"
        case "controlPoint": "region"
        default: nil
        }
    }

    var pageTitle: String? {
        guard let tableFeatureKind else { return nil }
        return switch tableFeatureKind {
        case "arc": "Arcs"
        case "node": "Nodes"
        case "region": "Regions"
        default: nil
        }
    }

    var typeLabel: String {
        switch featureKind {
        case "arc": "Arc"
        case "node": "Node"
        case "controlPoint": "Control Point"
        default: featureKind
        }
    }
}

struct GeometryTopologyTagDefinition: Codable, Identifiable, Sendable {
    let id: String
    let type: String
}

struct GeometryTopologyRecentTag: Codable, Identifiable, Sendable {
    let name: String
    let type: String
    let value: String
    var id: String { name + "\u{1f}" + value }
}

struct GeometryTopologySnapshot: Codable, Sendable {
    let revision: String
    let draftState: String
    let canEdit: Bool
    let isDirty: Bool
    let arcs: GeometryTopologyFeatureTable
    let regions: GeometryTopologyFeatureTable
    let nodes: GeometryTopologyFeatureTable
    let arcTags: [GeometryTopologyTagDefinition]
    let regionTags: [GeometryTopologyTagDefinition]
    let recentArcTags: [GeometryTopologyRecentTag]
    let recentRegionTags: [GeometryTopologyRecentTag]
    var map: GeometryTopologyMapData? = nil
    var canUndo = false
    var canRedo = false
    var completion: GeometryTopologyCompletionResult? = nil
}

@MainActor
protocol GeometryTopologyProvider {
    func modelRequest(for asset: ProjectAsset) -> GeometryTopologyModelRequest
    func load(_ model: GeometryTopologyModelRequest, expectedRevision: String?) async throws -> GeometryTopologySnapshot
    func edit(_ model: GeometryTopologyModelRequest, revision: String, draftState: String,
              mutation: GeometryTopologyMutation) async throws -> GeometryTopologySnapshot
    func save(_ model: GeometryTopologyModelRequest, revision: String,
              draftState: String) async throws -> GeometryTopologySnapshot
    func arcPoints(_ model: GeometryTopologyModelRequest, revision: String, draftState: String,
                   arcFID: Int) async throws -> GeometryTopologyArcPointsSnapshot
    func inspectRecipe(_ model: GeometryTopologyModelRequest, revision: String, draftState: String,
                       controlPointFIDs: [Int], recipeText: String?) async throws -> GeometryTopologyRecipeSnapshot
    func filter(_ request: GeometryTopologyFilterRequest) async throws -> GeometryTopologyFilterSnapshot
}

extension GeometryTopologyProvider {
    func arcPoints(_ model: GeometryTopologyModelRequest, revision: String, draftState: String,
                   arcFID: Int) async throws -> GeometryTopologyArcPointsSnapshot {
        throw GeometryTopologyProviderError.toolUnavailable
    }

    func inspectRecipe(_ model: GeometryTopologyModelRequest, revision: String, draftState: String,
                       controlPointFIDs: [Int], recipeText: String?) async throws -> GeometryTopologyRecipeSnapshot {
        throw GeometryTopologyProviderError.toolUnavailable
    }

    func filter(_ request: GeometryTopologyFilterRequest) async throws -> GeometryTopologyFilterSnapshot {
        throw GeometryTopologyProviderError.toolUnavailable
    }
}

enum GeometryTopologyProviderError: Error {
    case toolUnavailable
}

@MainActor
final class BackendGeometryTopologyProvider: GeometryTopologyProvider {
    private let client: BackendProcessClient
    private let currentProject: @MainActor () -> ProjectDocument?

    init(client: BackendProcessClient? = nil,
         currentProject: @escaping @MainActor () -> ProjectDocument? = { nil }) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
        self.currentProject = currentProject
    }

    func modelRequest(for asset: ProjectAsset) -> GeometryTopologyModelRequest {
        let project = currentProject()
        return GeometryTopologyModelRequest(assetPath: asset.url.path, kind: "Geometry",
            projectPath: project?.url?.path, projectXml: project?.editorXML)
    }

    func load(_ model: GeometryTopologyModelRequest, expectedRevision: String? = nil) async throws -> GeometryTopologySnapshot {
        struct Request: Encodable, Sendable { let model: GeometryTopologyModelRequest; let revision: String? }
        return try await client.request("topology.load", parameters: Request(model: model, revision: expectedRevision), as: GeometryTopologySnapshot.self)
    }

    func edit(_ model: GeometryTopologyModelRequest, revision: String, draftState: String,
              mutation: GeometryTopologyMutation) async throws -> GeometryTopologySnapshot {
        struct Request: Encodable, Sendable {
            let model: GeometryTopologyModelRequest
            let revision: String
            let draftState: String
            let mutation: GeometryTopologyMutation
        }
        return try await client.request("topology.edit", parameters: Request(model: model, revision: revision,
            draftState: draftState, mutation: mutation), as: GeometryTopologySnapshot.self)
    }

    func save(_ model: GeometryTopologyModelRequest, revision: String,
              draftState: String) async throws -> GeometryTopologySnapshot {
        struct Request: Encodable, Sendable {
            let model: GeometryTopologyModelRequest
            let revision: String
            let draftState: String
        }
        return try await client.request("topology.save", parameters: Request(model: model, revision: revision,
            draftState: draftState), as: GeometryTopologySnapshot.self)
    }

    func arcPoints(_ model: GeometryTopologyModelRequest, revision: String, draftState: String,
                   arcFID: Int) async throws -> GeometryTopologyArcPointsSnapshot {
        let request = GeometryTopologyArcPointsRequest(model: model, revision: revision,
            draftState: draftState, arcFID: arcFID)
        return try await client.request("topology.arcPoints", parameters: request,
            as: GeometryTopologyArcPointsSnapshot.self)
    }

    func inspectRecipe(_ model: GeometryTopologyModelRequest, revision: String, draftState: String,
                       controlPointFIDs: [Int], recipeText: String?) async throws -> GeometryTopologyRecipeSnapshot {
        let request = GeometryTopologyRecipeRequest(model: model, revision: revision,
            draftState: draftState, controlPointFIDs: controlPointFIDs, recipeText: recipeText)
        return try await client.request("topology.recipe", parameters: request,
            as: GeometryTopologyRecipeSnapshot.self)
    }

    func filter(_ request: GeometryTopologyFilterRequest) async throws -> GeometryTopologyFilterSnapshot {
        try await client.request("topology.filter", parameters: request,
            as: GeometryTopologyFilterSnapshot.self)
    }
}
