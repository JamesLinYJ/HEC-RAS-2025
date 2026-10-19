import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendGdalInformationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func runtimeInformationUsesTheBundledBackendAndLoadedGDALRuntime() async throws {
        let executablePath = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let executableURL = URL(fileURLWithPath: executablePath).standardizedFileURL
        let session = GdalInformationSession()

        await session.refresh(using: BackendProcessClient(executableURL: executableURL))

        let information = try #require(session.information)
        #expect(session.errorMessage == nil)
        #expect(!session.isLoading)
        #expect(FileManager.default.fileExists(atPath: information.directory))
        #expect(FileManager.default.fileExists(atPath: information.dataDirectory))
        #expect(!information.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!information.releaseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let packagedBackendDirectory = executableURL.deletingLastPathComponent().standardizedFileURL.path
        #expect(information.expectedLocations.contains { location in
            URL(fileURLWithPath: location).standardizedFileURL.path == packagedBackendDirectory
        })
        #expect(!information.expectedLocations.contains(".\\GDAL"))
        #expect(!information.expectedLocations.contains("C:\\Work\\GDAL"))
    }
}
