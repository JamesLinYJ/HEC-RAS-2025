import CryptoKit
import Foundation
import RASWorkspaceCore

struct CatalogNValuePreviewRequest: Codable, Sendable {
    let projectPath: String
    let assetPath: String
    let projectRevision: String
    let revision: String
}

struct CatalogNValuePreviewSnapshot: Decodable, Sendable {
    let revision: String
    let projectRevision: String
    let mode: String
    let raster: SpatialGridPreview?
    let legendStops: [CatalogNValuePreviewLegendStop]
    let histogram: CatalogNValuePreviewHistogram?
}

struct CatalogNValuePreviewLegendStop: Decodable, Sendable, Identifiable {
    let value: Double
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    var id: String { "\(value.bitPattern)-\(red)-\(green)-\(blue)-\(alpha)" }
}

struct CatalogNValuePreviewHistogram: Decodable, Sendable {
    let minimum: Double
    let maximum: Double
    let binWidth: Double
    let binArea: [Double]
}

struct BackendCatalogNValuePreviewProvider: Sendable {
    let client: BackendProcessClient

    func load(asset: ProjectAsset, projectURL: URL, revision: String) async throws -> CatalogNValuePreviewSnapshot {
        let projectRevision = try await CatalogPreviewFileRevision.sha256(projectURL)
        guard try await CatalogPreviewFileRevision.sha256(asset.url) == revision else {
            throw BackendServiceError(code: "sourceChanged", message: "Refresh the N-value source summary before rendering its preview.")
        }
        let request = CatalogNValuePreviewRequest(projectPath: projectURL.path,
            assetPath: asset.url.path, projectRevision: projectRevision, revision: revision)
        let snapshot = try await client.request("nvalue.preview", parameters: request,
            as: CatalogNValuePreviewSnapshot.self)
        guard snapshot.revision == revision, snapshot.projectRevision == projectRevision else {
            throw BackendServiceError(code: "sourceChanged", message: "The selected N-value preview returned a different source revision.")
        }
        guard try await CatalogPreviewFileRevision.sha256(projectURL) == projectRevision,
              try await CatalogPreviewFileRevision.sha256(asset.url) == revision else {
            throw BackendServiceError(code: "sourceChanged", message: "The selected N-value source changed while its preview was loading.")
        }
        return snapshot
    }
}

enum CatalogPreviewFileRevision {
    static func sha256(_ url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            return SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
        }.value
    }
}
