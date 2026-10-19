import Combine
import Foundation
import RASWorkspaceCore

struct SurfaceCatalogEntry: Codable, Sendable, Equatable {
    let path: String
    let category: String?
    let error: String?
}

@MainActor
final class SurfaceCatalogSession: ObservableObject {
    @Published private(set) var entries: [String: SurfaceCatalogEntry] = [:]
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private var revision = UUID()
    func load(_ assets: [ProjectAsset], provider: (any ModelEditorProvider)?) async {
        let revision = UUID(); self.revision = revision
        entries = [:]; error = nil; busy = provider != nil
        defer { if self.revision == revision { busy = false } }
        guard let provider else { return }
        do {
            let result = try await provider.catalogSurfaceLayers(assets)
            guard self.revision == revision, !Task.isCancelled else { return }
            entries = try Self.index(result, for: assets)
        } catch {
            guard self.revision == revision, !Task.isCancelled else { return }
            self.error = L10n.text(error.localizedDescription)
        }
    }
    // The host returns physical paths; Foundation can retain a /var alias or
    // a user-selected symlink. Match physical identity, then keep the caller's
    // asset ID as the lookup key so navigation and relative XML stay intact.
    static func index(_ result: [SurfaceCatalogEntry], for assets: [ProjectAsset]) throws -> [String: SurfaceCatalogEntry] {
        let grouped = Dictionary(grouping: result) { SourceFilePaths.canonical(URL(fileURLWithPath: $0.path)) }
        var indexed: [String: SurfaceCatalogEntry] = [:]
        for asset in assets where asset.section == .surfaceLayers && asset.isModelFile {
            let matches = grouped[SourceFilePaths.canonical(asset.url)] ?? []
            guard let entry = matches.first else { continue }
            guard matches.allSatisfy({ $0.category == entry.category && $0.error == entry.error }) else {
                throw ProjectFileError.invalid("The surface layer catalog returned conflicting identities.")
            }
            indexed[asset.id] = entry
        }
        return indexed
    }
    func invalidate() { revision = UUID(); entries = [:]; error = nil; busy = false }
}
