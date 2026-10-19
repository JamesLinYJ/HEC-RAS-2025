import Foundation
import RASWorkspaceCore

struct DSSRecordReadRequest: Sendable {
    let sourcePath: String
    let sourceRevision: String
    let recordPaths: [String]
}

struct DSSRecordReadResult: Decodable, Identifiable, Sendable {
    struct TimeSeries: Decodable, Sendable {
        let times: [String]
        let values: [Double?]
        let qualities: [Int]?
        let units: String
        let dataType: String
    }

    struct PairedCurve: Decodable, Sendable {
        let label: String
        let values: [Double?]
    }

    struct PairedData: Decodable, Sendable {
        let ordinates: [Double?]
        let curves: [PairedCurve]
        let independentUnits: String
        let dependentUnits: String
        let independentType: String
        let dependentType: String
    }

    struct Location: Decodable, Sendable {
        let x: Double?
        let y: Double?
        let z: Double?
        let coordinateSystem: String
        let coordinateID: Int
        let horizontalUnits: Int
        let horizontalDatum: Int
        let verticalUnits: Int
        let verticalDatum: Int
        let timeZoneName: String
        let supplemental: String
    }

    let path: String
    let recordType: String
    let kind: String
    let error: String?
    let timeSeries: TimeSeries?
    let pairedData: PairedData?
    let location: Location?

    var id: String { path }
}

@MainActor
final class BackendDSSRecordProvider: ExternalRecordProvider {
    private struct CatalogParameters: Encodable, Sendable {
        let path: String
    }

    private struct CatalogEntry: Decodable, Sendable {
        let path: String
        let recordType: String
        let parts: [String]
        let comprisingPaths: [String]
    }

    private struct CatalogResponse: Decodable, Sendable {
        let path: String
        let revision: String
        let records: [CatalogEntry]
    }

    private struct ReadParameters: Encodable, Sendable {
        let path: String
        let revision: String
        let recordPaths: [String]
    }

    private struct ReadResponse: Decodable, Sendable {
        let path: String
        let revision: String
        let records: [DSSRecordReadResult]
    }

    private let client: BackendProcessClient
    var authorizeFolders: (@MainActor ([URL]) -> Bool)?

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func records(connection: ProjectConnection, directory: URL,
                 mappings: [PathMapping]) async throws -> [ExternalRecord] {
        let source = try resolveAuthorizedDSSFile(connection: connection, directory: directory, mappings: mappings)
        try Task.checkCancellation()

        let response: CatalogResponse = try await client.request(
            "dss.catalog", parameters: CatalogParameters(path: source.path), as: CatalogResponse.self)
        try Task.checkCancellation()
        guard response.path == source.path, Self.isSHA256(response.revision) else {
            throw Self.failure("The DSS catalog returned an invalid source path or revision.")
        }
        var paths = Set<String>()
        guard response.records.allSatisfy({
            !$0.path.isEmpty && $0.parts.count == 6 && paths.insert($0.path).inserted
        }) else {
            throw Self.failure("The DSS catalog contains an empty path, a duplicate path, or an invalid six-part record.")
        }
        return response.records.map { entry in
            ExternalRecord(path: entry.path, dataType: "", units: "", recordType: entry.recordType,
                           parts: entry.parts, comprisingPaths: entry.comprisingPaths,
                           sourcePath: response.path, sourceRevision: response.revision)
        }
    }

    func read(_ request: DSSRecordReadRequest) async throws -> [DSSRecordReadResult] {
        _ = try resolveAuthorizedDSSPath(request.sourcePath)
        try Task.checkCancellation()
        guard Self.isSHA256(request.sourceRevision), !request.recordPaths.isEmpty,
              request.recordPaths.allSatisfy({ !$0.isEmpty }),
              Set(request.recordPaths).count == request.recordPaths.count else {
            throw Self.failure("Select valid DSS records from one loaded catalog before reading.")
        }

        let response: ReadResponse = try await client.request(
            "dss.read",
            parameters: ReadParameters(path: request.sourcePath, revision: request.sourceRevision,
                                       recordPaths: request.recordPaths),
            as: ReadResponse.self)
        try Task.checkCancellation()
        guard response.path == request.sourcePath, response.revision == request.sourceRevision else {
            throw Self.failure("The DSS read response does not match the selected source revision.")
        }
        let returnedPaths = response.records.map(\.path)
        guard returnedPaths.count == request.recordPaths.count,
              Set(returnedPaths).count == returnedPaths.count,
              Set(returnedPaths) == Set(request.recordPaths) else {
            throw Self.failure("The DSS read response must contain exactly one result for each selected record.")
        }
        do {
            try DSSRecordPayloadValidator.validate(response.records)
        } catch let validationError as DSSRecordPayloadValidationError {
            throw BackendServiceError(code: "invalidDSSResponse", message: validationError.localizedMessage)
        }
        let byPath = Dictionary(uniqueKeysWithValues: response.records.map { ($0.path, $0) })
        return request.recordPaths.compactMap { byPath[$0] }
    }

    private func resolveAuthorizedDSSFile(connection: ProjectConnection, directory: URL,
                                          mappings: [PathMapping]) throws -> URL {
        guard ["File", "FileSystem"].contains(connection.type) else {
            throw Self.failure("Choose a File or FileSystem connection that points to one DSS file.")
        }
        let source = try connection.resolve(relativeTo: directory, mappings: mappings)
        guard source.pathExtension.lowercased() == "dss" else {
            throw Self.failure("The selected connection does not point to a DSS file.")
        }
        return try resolveAuthorizedDSSPath(source.path)
    }

    private func resolveAuthorizedDSSPath(_ path: String) throws -> URL {
        let source = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard source.isFileURL, source.pathExtension.lowercased() == "dss",
              FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw Self.failure("The external DSS file was not found or is not a regular file.")
        }
        let folder = source.deletingLastPathComponent()
        guard authorizeFolders?([folder]) == true else {
            throw Self.failure("Authorize the folder containing this DSS file before browsing its records.")
        }
        return source
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func failure(_ message: String) -> BackendServiceError {
        BackendServiceError(code: "invalidDSSResponse", message: L10n.text(message))
    }
}
