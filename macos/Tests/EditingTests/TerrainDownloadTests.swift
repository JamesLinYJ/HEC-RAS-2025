import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class DeferredTerrainProvider: TerrainDownloadProvider {
    static func tile(_ id: String = "original-tile", state: TerrainTile.State = .available) -> TerrainTile {
        TerrainTile(id: id, title: "Task fixture", publicationDate: nil, sizeInBytes: nil, resolution: "", cellSize: "", metadataURL: nil, boundary: [], state: state, progressPercent: nil)
    }
    private var completion: CheckedContinuation<TerrainTile, any Error>?
    private var started: CheckedContinuation<Void, Never>?
    var progress: (@MainActor (Double?) -> Void)?
    func tiles(in extent: ViewportRequest?) async throws -> [TerrainTile] { [Self.tile()] }
    func download(_ id: String, progress: @escaping @MainActor (Double?) -> Void) async throws -> TerrainTile {
        self.progress = progress
        return try await withCheckedThrowingContinuation {
            completion = $0; started?.resume(); started = nil
        }
    }
    func hide(_ id: String) async throws -> TerrainTile { Self.tile(id) }
    func waitForStart() async {
        if completion != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ tile: TerrainTile) { completion?.resume(returning: tile); completion = nil }
}

struct TerrainDownloadTests {
    @Test @MainActor
    func cancelledViewRejectsLateProgressAndCompletion() async throws {
        let provider = DeferredTerrainProvider(), session = TerrainDownloadSession()
        await session.refresh(provider: provider, extent: nil)
        let jobs = session.download(["original-tile"], provider: provider)
        await provider.waitForStart()
        provider.progress?(45)
        #expect(session.tiles.first?.progressPercent == 45)
        session.cancel()
        provider.progress?(90)
        provider.finish(DeferredTerrainProvider.tile(state: .importing))
        for job in jobs { await job.value }
        #expect(session.tiles.first?.progressPercent == 45)
        #expect(session.importingIDs.isEmpty)
        #expect(!session.isDownloading)
        #expect(session.error == nil)
    }
    @Test @MainActor
    func mismatchedDownloadIdentityCannotMarkTileImported() async throws {
        let provider = DeferredTerrainProvider(), session = TerrainDownloadSession()
        await session.refresh(provider: provider, extent: nil)
        let jobs = session.download(["original-tile"], provider: provider)
        await provider.waitForStart()
        provider.finish(DeferredTerrainProvider.tile("different-tile", state: .importing))
        for job in jobs { await job.value }
        #expect(session.importingIDs.isEmpty)
        #expect(session.tiles.first?.state == .available)
        #expect(!session.isDownloading)
        #expect(session.error != nil)
    }
}
