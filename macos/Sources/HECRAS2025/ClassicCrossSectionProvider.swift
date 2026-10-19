import CryptoKit
import Foundation
import RASWorkspaceCore

struct ClassicCrossSectionRow: Codable, Equatable, Identifiable, Sendable {
    let ordinal: Int
    let rowToken: String
    let nodeName: String
    let riverName: String
    let reachName: String
    let riverStation: String
    let profilePointCount: Int
    let usesOverride: Bool
    var id: Int { ordinal }
}
struct ClassicCrossSectionPoint: Codable, Equatable, Sendable {
    let ordinal: Int
    let station: Double?
    let elevation: Double?
}
struct ClassicCrossSectionCatalog: Codable, Sendable {
    let scopeID: String
    let sourcePath: String
    let sourceRevision: String
    let sourceName: String
    let contextToken: String
    let totalCount: Int
    let offset: Int
    let nextOffset: Int?
    let rows: [ClassicCrossSectionRow]
}
struct ClassicCrossSectionProfile: Codable, Sendable {
    let scopeID: String
    let sourcePath: String
    let sourceRevision: String
    let contextToken: String
    let row: ClassicCrossSectionRow
    let hasProfile: Bool
    let points: [ClassicCrossSectionPoint]
    let banks: [ClassicCrossSectionPoint]
}
protocol ClassicCrossSectionProvider: Sendable {
    func catalog(scopeID: UUID, source: URL, revision: String?, offset: Int) async throws -> ClassicCrossSectionCatalog
    func profile(scopeID: UUID, source: URL, revision: String, contextToken: String,
                 row: ClassicCrossSectionRow) async throws -> ClassicCrossSectionProfile
}

struct BackendClassicCrossSectionProvider: ClassicCrossSectionProvider {
    let client: BackendProcessClient

    func catalog(scopeID: UUID, source: URL, revision: String?, offset: Int) async throws -> ClassicCrossSectionCatalog {
        let identity = try await identity(source)
        if let revision, revision.uppercased() != identity.revision { throw sourceChanged() }
        let result: ClassicCrossSectionCatalog
        do {
            result = try await client.request("classic.crossSections.catalog",
                parameters: CatalogRequest(scopeID: scopeID.uuidString, sourcePath: identity.path,
                    expectedRevision: identity.revision, offset: offset, limit: 256), as: ClassicCrossSectionCatalog.self)
        } catch let error as BackendServiceError where error.code == "sourceChanged" {
            throw sourceChanged()
        }
        try await validateSource(scopeID: scopeID, source: source, path: result.sourcePath,
            revision: result.sourceRevision, token: result.contextToken, responseScope: result.scopeID,
            expected: identity)
        guard result.offset == offset, result.totalCount >= offset,
              result.rows.count <= 256, result.rows.count <= result.totalCount - offset,
              result.rows.enumerated().allSatisfy({ index, row in
                  row.ordinal == offset + index && row.profilePointCount >= 0
                      && row.rowToken == Self.rowToken(result.contextToken, row.ordinal)
              }),
              result.nextOffset == (offset + result.rows.count < result.totalCount ? offset + result.rows.count : nil),
              result.nextOffset == nil || !result.rows.isEmpty else { throw invalidReply() }
        return result
    }

    func profile(scopeID: UUID, source: URL, revision: String, contextToken: String,
                 row: ClassicCrossSectionRow) async throws -> ClassicCrossSectionProfile {
        let identity = try await identity(source)
        guard revision.uppercased() == identity.revision,
              contextToken == Self.contextToken(scopeID: scopeID, path: identity.path, revision: identity.revision),
              row.rowToken == Self.rowToken(contextToken, row.ordinal) else { throw sourceChanged() }
        let result: ClassicCrossSectionProfile
        do {
            result = try await client.request("classic.crossSections.profile",
                parameters: ProfileRequest(scopeID: scopeID.uuidString, sourcePath: identity.path,
                    expectedRevision: revision, contextToken: contextToken,
                    rowOrdinal: row.ordinal, rowToken: row.rowToken), as: ClassicCrossSectionProfile.self)
        } catch let error as BackendServiceError where error.code == "sourceChanged" {
            throw sourceChanged()
        }
        try await validateSource(scopeID: scopeID, source: source, path: result.sourcePath,
            revision: result.sourceRevision, token: result.contextToken, responseScope: result.scopeID,
            expected: identity)
        guard result.row == row, result.contextToken == contextToken,
              result.points.count == row.profilePointCount,
              result.hasProfile || result.points.isEmpty,
              result.banks.isEmpty || (result.banks.count == 2 && result.hasProfile),
              result.points.enumerated().allSatisfy({ $0.element.ordinal == $0.offset }),
              result.banks.enumerated().allSatisfy({ $0.element.ordinal == $0.offset }),
              (result.points + result.banks).allSatisfy({
                  ($0.station?.isFinite ?? true) && ($0.elevation?.isFinite ?? true)
              }) else { throw invalidReply() }
        return result
    }

    private func validateSource(scopeID: UUID, source: URL, path: String, revision: String,
                                token: String, responseScope: String, expected: Identity) async throws {
        try Task.checkCancellation()
        let current = try await identity(source)
        guard current.path == expected.path, current.revision == expected.revision,
              path == expected.path, revision == expected.revision,
              UUID(uuidString: responseScope) == scopeID,
              token == Self.contextToken(scopeID: scopeID, path: path, revision: revision) else { throw sourceChanged() }
    }
    private struct Identity: Sendable { let path: String; let revision: String }
    private func identity(_ source: URL) async throws -> Identity {
        let hashing = Task.detached {
            guard source.isFileURL else { throw invalidReply() }
            let path = SourceFilePaths.canonical(source)
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                try Task.checkCancellation()
                guard let block = try handle.read(upToCount: 1_048_576), !block.isEmpty else { break }
                hasher.update(data: block)
            }
            return Identity(path: path, revision: hasher.finalize().map { String(format: "%02X", $0) }.joined())
        }
        return try await withTaskCancellationHandler {
            try await hashing.value
        } onCancel: { hashing.cancel() }
    }
    static func contextToken(scopeID: UUID, path: String, revision: String) -> String {
        hash(scopeID.uuidString.uppercased() + "|" + revision + "|" + path)
    }
    static func rowToken(_ context: String, _ ordinal: Int) -> String { hash(context + "|" + String(ordinal)) }
    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02X", $0) }.joined()
    }
    private struct CatalogRequest: Encodable, Sendable {
        let scopeID: String; let sourcePath: String; let expectedRevision: String; let offset: Int; let limit: Int
    }
    private struct ProfileRequest: Encodable, Sendable {
        let scopeID: String; let sourcePath: String; let expectedRevision: String
        let contextToken: String; let rowOrdinal: Int; let rowToken: String
    }
}

private func sourceChanged() -> BackendServiceError {
    .init(code: "sourceChanged", message: "The cross-section source changed. Reload and select the section again.")
}
private func invalidReply() -> BackendServiceError {
    .init(code: "protocolFailure", message: "The cross-section source returned an invalid selection or profile.")
}
