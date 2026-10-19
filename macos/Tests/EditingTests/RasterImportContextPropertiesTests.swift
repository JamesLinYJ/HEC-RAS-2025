import Foundation
import Testing
@testable import HECRAS2025

@MainActor
private final class RasterImportContextPropertiesProviderFixture: RasterImportContextPropertiesProvider {
    var revisionByPath: [String: String] = [:]
    var valueByPath: [String: String] = [:]
    private(set) var requests: [[String]] = []

    func inspect(filePaths: [String], compareProjectionWKT: String?) async throws
        -> RasterImportContextPropertiesSnapshot {
        requests.append(filePaths)
        return RasterImportContextPropertiesSnapshot(sources: filePaths.map { path in
            RasterImportContextSource(path: path,
                revision: revisionByPath[path] ?? String(repeating: "A", count: 64),
                info: RasterImportContextInfo(fileName: URL(fileURLWithPath: path).lastPathComponent,
                    directory: URL(fileURLWithPath: path).deletingLastPathComponent().path,
                    rasterProjection: "Source CRS", projectionFriendlyText: "Matches Local",
                    overviewsCount: 1, overviews: ["8x8"], cellSize: "1.00", size: "512 Bytes",
                    uncompressedSize: "256 Bytes", compressionRatio: "0.5x", driver: valueByPath[path] ?? "GTiff",
                    bandCount: 1, unitSystem: "SI"),
                stats: RasterImportContextStats(min: "1", max: "8", mean: "4.5", standardDeviation: "2.3"),
                error: nil)
        })
    }
}

@Suite(.serialized)
struct RasterImportContextPropertiesTests {
    @Test @MainActor
    func forceSetAppliesToSelectedDTOsAndSurvivesOnlyTheExactSourceRevision() async {
        let provider = RasterImportContextPropertiesProviderFixture()
        let session = RasterImportContextPropertiesSession(provider: provider)
        let first = "/tmp/raster-import-context-a.tif"
        let second = "/tmp/raster-import-context-b.tif"
        provider.valueByPath[first] = "GTiff A"
        provider.valueByPath[second] = "GTiff B"

        await session.select(filePaths: [first, second])
        #expect(session.sources.count == 2)
        #expect(session.aggregate(.file, field: .driver) == .mixed)
        #expect(session.forceSet(.file, field: .driver, value: "Reviewed source"))
        #expect(session.sources.allSatisfy { $0.info?.driver == "Reviewed source" })

        await session.select(filePaths: [second])
        #expect(session.sources.count == 1 && session.sources.first?.info?.driver == "Reviewed source",
            "The source ForceSet mutates selected RasterInfo DTOs, and cached DTO changes survive selection toggles for the same path and revision.")
        provider.revisionByPath[second] = String(repeating: "B", count: 64)
        await session.select(filePaths: [second])
        #expect(session.sources.count == 1 && session.sources.first?.info?.driver == "GTiff B",
            "A changed source revision installs a fresh inspected DTO instead of carrying a stale ForceSet value.")
        #expect(provider.requests.count == 3)
    }
}
