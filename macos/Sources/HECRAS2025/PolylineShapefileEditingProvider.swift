import Foundation
import RASWorkspaceCore

struct PolylineShapefileDraftSaveRecord: Encodable, Sendable {
    let attributeSourceFeatureIndex: Int?
    let coordinates: [[Double]]
    let zValues: [String]?
    let mValues: [String]?
}

private struct PolylineShapefileDraftSaveRequest: Encodable, Sendable {
    let sourcePath: String
    let projectionStatus: String
    let sourceProjectionWKT: String?
    let targetProjectionWKT: String?
    let expectedFamily: MapSourceFamilyCapture
    let records: [PolylineShapefileDraftSaveRecord]
}

struct PolylineShapefileDraftSavedRecord: Decodable, Sendable {
    let recordIndex: Int
    let sourceCoordinates: [[Double]]
    let zValues: [String]?
    let mValues: [String]?
}

struct PolylineShapefileDraftSaveReceipt: Decodable, Sendable {
    let family: MapSourceFamilyCapture
    let records: [PolylineShapefileDraftSavedRecord]
}

@MainActor
final class PolylineShapefileEditingProvider {
    private let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func captureFamily(sourcePath: String) async throws -> MapSourceFamilyCapture {
        guard URL(fileURLWithPath: sourcePath).pathExtension.lowercased() == "shp" else {
            throw PolylineMapEditingError.invalidScope
        }
        struct Request: Encodable, Sendable { let sourcePath: String }
        let family = try await client.request("map.vector.captureShapefile",
            parameters: Request(sourcePath: sourcePath), as: MapSourceFamilyCapture.self)
        return try MapShapefileVectorConverter.validateFamily(family,
            sourcePath: SourceFilePaths.canonical(URL(fileURLWithPath: sourcePath)),
            sourceRevision: family.files.first(where: { $0.role == "source" })?.revision ?? "")
    }

    func save(scope: PolylineMapEditingScope, projectionStatus: String,
              sourceProjectionWKT: String?, targetProjectionWKT: String?,
              expectedFamily: MapSourceFamilyCapture,
              records: [PolylineShapefileDraftSaveRecord]) async throws -> PolylineShapefileDraftSaveReceipt {
        guard scope.canonicalPath == SourceFilePaths.canonical(URL(fileURLWithPath: expectedFamily.sourcePath)),
              expectedFamily.family == "shapefile" else {
            throw PolylineMapEditingError.invalidScope
        }
        let receipt = try await client.request("map.vector.savePolylineShapefileDraft",
            parameters: PolylineShapefileDraftSaveRequest(sourcePath: scope.canonicalPath,
                projectionStatus: projectionStatus, sourceProjectionWKT: sourceProjectionWKT,
                targetProjectionWKT: targetProjectionWKT, expectedFamily: expectedFamily,
                records: records), as: PolylineShapefileDraftSaveReceipt.self)
        let sourceRevision = receipt.family.files.first(where: { $0.role == "source" })?.revision ?? ""
        _ = try MapShapefileVectorConverter.validateFamily(receipt.family,
            sourcePath: scope.canonicalPath, sourceRevision: sourceRevision)
        guard receipt.records.count == records.count,
              receipt.records.enumerated().allSatisfy({ index, record in
                  record.recordIndex == index && record.sourceCoordinates.count == records[index].coordinates.count
                      && record.zValues == records[index].zValues && record.mValues == records[index].mValues
                      && record.sourceCoordinates.allSatisfy { $0.count == 2 && $0[0].isFinite && $0[1].isFinite }
              }) else {
            throw BackendServiceError(code: "protocolFailure", message: "The Shapefile save reply does not match the captured line records.")
        }
        return receipt
    }
}
