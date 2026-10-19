import Foundation
import RASWorkspaceCore

struct TerrainTopologyResponse: Decodable, Sendable {
    let snapshot: BackendModelProvider.ModelSnapshot
    let topology: TerrainTopologyData
}

extension BackendModelProvider {
    func editTerrainTopology(_ asset: ProjectAsset, inputID: String,
                             operation: TerrainTopologyOperation, featureIDs: [String],
                             points: [TerrainMapCoordinate], mapCellSize: Double?,
                             edits: EditorEdits) async throws -> TerrainTopologyResponse {
        let command = TerrainTopologyCommand(operation: operation, featureIDs: featureIDs,
            points: points, mapCellSize: mapCellSize)
        if operation == .load || operation == .sortProfile {
            return try await editTerrainTopology(asset, inputID: inputID, command: command,
                expectedDraftIdentity: nil, edits: edits)
        }

        // The compatibility overload predates the typed draft identity. Capture
        // it from the same edits/request context before forwarding the command;
        // never turn a legacy caller into an identity-free mutation.
        let loaded = try await editTerrainTopology(asset, inputID: inputID,
            command: TerrainTopologyCommand(operation: .load), expectedDraftIdentity: nil,
            edits: edits)
        return try await editTerrainTopology(asset, inputID: inputID, command: command,
            expectedDraftIdentity: loaded.topology.draftIdentity, edits: edits)
    }

    func editTerrainTopology(_ asset: ProjectAsset, inputID: String,
                             command: TerrainTopologyCommand, expectedDraftIdentity: String?,
                             edits: EditorEdits) async throws -> TerrainTopologyResponse {
        struct Request: Encodable, Sendable {
            let model: ModelSaveRequest
            let inputId: String
            let operation: TerrainTopologyOperation
            let featureIDs: [String]
            let points: [TerrainMapCoordinate]
            let mapCellSize: Double?
            let expectedDraftIdentity: String?
            let splitMode: String?
            let vertexIndex: Int?
            let metadataKind: String?
            let metadataColumn: String?
            let metadataValue: String?
        }
        return try await client.request("model.terrainTopology", parameters: Request(
            model: try saveRequest(asset, changes: edits), inputId: inputID,
            operation: command.operation, featureIDs: command.featureIDs, points: command.points,
            mapCellSize: command.mapCellSize, expectedDraftIdentity: expectedDraftIdentity,
            splitMode: command.splitMode?.rawValue, vertexIndex: command.vertexIndex,
            metadataKind: command.metadataKind, metadataColumn: command.metadataColumn,
            metadataValue: command.metadataValue))
    }
}
