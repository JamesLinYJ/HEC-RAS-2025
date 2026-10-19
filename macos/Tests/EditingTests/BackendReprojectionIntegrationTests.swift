import Foundation
import Testing
import RASWorkspaceCore
@testable import HECRAS2025

struct BackendReprojectionIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func bundledBackendTransformsRowsIndependentlyAndReportsMissingProjectProjection() async throws {
        let executable = URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        let provider = BackendReprojectionProvider(
            client: BackendProcessClient(executableURL: executable))

        let rows = [
            ReprojectionInputRow(id: "valid", xText: "-121.74", yText: "38.55"),
            ReprojectionInputRow(id: "blank", xText: "", yText: ""),
            ReprojectionInputRow(id: "invalid", xText: "not-a-coordinate", yText: "38.55")
        ]
        let forward = try await provider.transform(ReprojectionRequest(
            sourceOption: ReprojectionOption.wgs84.rawValue,
            destinationOption: ReprojectionOption.webMercator.rawValue,
            projectProjection: nil,
            sourceCustomProjectionText: "",
            destinationCustomProjectionText: "",
            rows: rows,
            numberCulture: "en-US"))

        #expect(forward.errorCode == nil)
        #expect(forward.rows.map(\.id) == ["valid", "blank", "invalid"])
        #expect(forward.rows.map(\.status) == [.transformed, .blank, .invalid])
        let projected = try #require(forward.rows.first)
        let projectedX = try #require(projected.x)
        let projectedY = try #require(projected.y)
        #expect(abs(projectedX) > 1_000_000)
        #expect(abs(projectedY) > 1_000_000)
        #expect(forward.rows[1].x == nil && forward.rows[1].y == nil)
        #expect(forward.rows[2].x == nil && forward.rows[2].y == nil)

        let reverse = try await provider.transform(ReprojectionRequest(
            sourceOption: ReprojectionOption.webMercator.rawValue,
            destinationOption: ReprojectionOption.wgs84.rawValue,
            projectProjection: nil,
            sourceCustomProjectionText: "",
            destinationCustomProjectionText: "",
            rows: [ReprojectionInputRow(
                id: "round-trip", xText: String(projectedX), yText: String(projectedY))],
            numberCulture: "en-US"))
        let geographic = try #require(reverse.rows.first)
        #expect(geographic.status == .transformed)
        let longitude = try #require(geographic.x)
        let latitude = try #require(geographic.y)
        #expect(abs(longitude - (-121.74)) < 0.000001)
        #expect(abs(latitude - 38.55) < 0.000001)

        let frenchInput = try await provider.transform(ReprojectionRequest(
            sourceOption: ReprojectionOption.wgs84.rawValue,
            destinationOption: ReprojectionOption.webMercator.rawValue,
            projectProjection: nil,
            sourceCustomProjectionText: "",
            destinationCustomProjectionText: "",
            rows: [ReprojectionInputRow(id: "french", xText: "-121,74", yText: "38,55")],
            numberCulture: "fr-FR"))
        let frenchResult = try #require(frenchInput.rows.first)
        #expect(frenchResult.status == .transformed)
        #expect(abs((try #require(frenchResult.x)) - projectedX) < 0.000001)
        #expect(abs((try #require(frenchResult.y)) - projectedY) < 0.000001)

        let localProject = ProjectionDefinitionDraft(type: "Local", value: "SI")
        let unavailable = try await provider.transform(ReprojectionRequest(
            sourceOption: ReprojectionOption.project.rawValue,
            destinationOption: ReprojectionOption.wgs84.rawValue,
            projectProjection: localProject,
            sourceCustomProjectionText: "",
            destinationCustomProjectionText: "",
            rows: [ReprojectionInputRow(id: "local-project", xText: "1", yText: "2")]))
        #expect(unavailable.errorCode == "noProjectSource")
        #expect(unavailable.rows == [ReprojectionRowResult(
            id: "local-project", status: .unavailable, x: nil, y: nil)])
    }
}
