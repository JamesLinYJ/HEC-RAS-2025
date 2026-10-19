import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct SurfaceCatalogIdentityTests {
    @Test @MainActor
    func physicalHostPathsMapToTheOriginalAssetIdentityWithoutAcceptingRawInputs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("roughness.h5"), alias = root.appendingPathComponent("selected-link.h5")
        try Data().write(to: source)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let asset = ProjectAsset(url: alias, section: .surfaceLayers)
        let raw = ProjectAsset(url: root.appendingPathComponent("backing.tif"), section: .surfaceLayers)
        let entries = try SurfaceCatalogSession.index([
            .init(path: SourceFilePaths.canonical(source), category: "NValues", error: nil),
            .init(path: raw.id, category: "NValues", error: nil)
        ], for: [asset, raw])
        #expect(entries.count == 1 && entries[asset.id]?.category == "NValues")
        #expect(entries[raw.id] == nil)
        #expect(asset.url.path == alias.path)
        #expect(throws: (any Error).self) {
            try SurfaceCatalogSession.index([
                .init(path: source.path, category: "NValues", error: nil),
                .init(path: alias.path, category: "Classifications", error: nil)
            ], for: [asset])
        }
    }
}
