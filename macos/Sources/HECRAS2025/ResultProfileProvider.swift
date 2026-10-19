import Foundation
import RASWorkspaceCore

struct ResultProfileIdentity: Hashable, Sendable {
    let resultPath: String
    let revision: String
}

struct ResultProfileVariable: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let elementKind: String
    let quantity: String
    let units: String
}

struct ResultProfileOutputBlock: Decodable, Identifiable, Sendable {
    let name: String
    let profileCount: Int
    let profileNames: [String]
    let times: [String]
    let variables: [ResultProfileVariable]
    var id: String { name }
}

struct ResultProfileFlowArea: Decodable, Identifiable, Sendable {
    let index: Int
    let name: String
    let cellCount: Int
    let faceCount: Int
    var id: Int { index }
    func elementCount(for kind: String) -> Int? {
        switch kind {
        case "Face": faceCount
        case "Cell": cellCount
        default: nil
        }
    }
}

struct ResultProfileCatalog: Decodable, Sendable {
    let resultPath: String
    let revision: String
    let resultName: String
    let outputBlocks: [ResultProfileOutputBlock]
    let flowAreas: [ResultProfileFlowArea]
}

struct ResultProfilePoint: Decodable, Identifiable, Sendable {
    let profileIndex: Int
    let profileName: String
    let time: String
    let value: Double?
    var id: Int { profileIndex }
}

struct ResultProfileSeries: Decodable, Sendable {
    let resultPath: String
    let revision: String
    let resultName: String
    let outputBlockName: String
    let variable: String
    let flowAreaName: String
    let flowAreaIndex: Int
    let elementIndex: Int
    let elementKind: String
    let quantity: String
    let units: String
    let available: Bool
    let unavailableReason: String?
    let points: [ResultProfilePoint]
}

struct ResultProfileMapElement: Decodable, Identifiable, Sendable {
    let elementIndex: Int
    let paths: [[GeometryTopologyCoordinate]]
    var id: Int { elementIndex }
}

struct ResultProfileMapResult: Decodable, Sendable {
    let resultPath: String
    let revision: String
    let flowAreaName: String
    let flowAreaIndex: Int
    let elementKind: String
    let available: Bool
    let unavailableReason: String?
    let sourceExtent: GeometryTopologyExtent?
    let requestedExtent: GeometryTopologyExtent?
    let totalElements: Int
    let intersectingElements: Int?
    let returnedElements: Int
    let elementLimit: Int
    let vertexLimit: Int
    let isComplete: Bool
    let requiresZoom: Bool
    let elements: [ResultProfileMapElement]
}

struct ResultProfileSelection: Hashable, Sendable {
    let outputBlockName: String
    let variableID: String
    let flowAreaIndex: Int
    let elementIndex: Int
}

@MainActor
protocol ResultProfileProvider {
    func loadCatalog(resultPath: String, revision: String) async throws -> ResultProfileCatalog
    func loadMap(resultPath: String, revision: String, flowAreaIndex: Int, elementKind: String,
                 extent: GeometryTopologyExtent?, limit: Int) async throws -> ResultProfileMapResult
    func readSeries(resultPath: String, revision: String, selection: ResultProfileSelection) async throws -> ResultProfileSeries
}

@MainActor
struct BackendResultProfileProvider: ResultProfileProvider {
    let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func loadCatalog(resultPath: String, revision: String) async throws -> ResultProfileCatalog {
        struct Request: Encodable, Sendable { let resultPath: String; let revision: String }
        return try await client.request("result.profileCatalog", parameters: Request(resultPath: resultPath, revision: revision), as: ResultProfileCatalog.self)
    }

    func loadMap(resultPath: String, revision: String, flowAreaIndex: Int, elementKind: String,
                 extent: GeometryTopologyExtent?, limit: Int) async throws -> ResultProfileMapResult {
        struct Request: Encodable, Sendable {
            let resultPath: String
            let revision: String
            let flowAreaIndex: Int
            let elementKind: String
            let extent: GeometryTopologyExtent?
            let limit: Int
        }
        let request = Request(resultPath: resultPath, revision: revision, flowAreaIndex: flowAreaIndex,
            elementKind: elementKind, extent: extent, limit: limit)
        return try await client.request("result.profileMap", parameters: request, as: ResultProfileMapResult.self)
    }

    func readSeries(resultPath: String, revision: String, selection: ResultProfileSelection) async throws -> ResultProfileSeries {
        struct Request: Encodable, Sendable {
            let resultPath: String
            let revision: String
            let outputBlockName: String
            let variable: String
            let flowAreaIndex: Int
            let elementIndex: Int
        }
        let request = Request(resultPath: resultPath, revision: revision, outputBlockName: selection.outputBlockName,
            variable: selection.variableID, flowAreaIndex: selection.flowAreaIndex, elementIndex: selection.elementIndex)
        return try await client.request("result.profile", parameters: request, as: ResultProfileSeries.self)
    }
}
