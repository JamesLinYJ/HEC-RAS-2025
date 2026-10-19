import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct DSSRecordProviderIntegrationTests {
    @Test @MainActor func bundledProviderReadsCondensedDSSRecordsWithoutChangingSourceBytes() async throws {
        let executablePath = try #require(
            ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"],
            "Set HECRAS_BACKEND_TEST_EXECUTABLE to the final app bundle backend executable.")
        let executable = URL(fileURLWithPath: executablePath).standardizedFileURL
        try #require(executable.isFileURL && FileManager.default.isExecutableFile(atPath: executable.path),
                     "The configured DSS backend executable must exist and be executable.")
        let directoryValue = try #require(
            ProcessInfo.processInfo.environment["HECRAS_DSS_ACCEPTANCE_DIRECTORY"],
            "Set HECRAS_DSS_ACCEPTANCE_DIRECTORY to the generated R28 DSS fixture directory.")
        let directory = URL(fileURLWithPath: directoryValue, isDirectory: true).standardizedFileURL
        let source = directory.appendingPathComponent("records.dss").standardizedFileURL
        let originalBytes = try Data(contentsOf: source)
        let sourceRevision = SHA256.hash(data: originalBytes).map { String(format: "%02x", $0) }.joined()

        let connection = ProjectConnection(id: "round28-dss-fixture", name: "R28 DSS fixture", type: "File",
                                           relativePath: "", absolutePath: source.path)
        let provider = BackendDSSRecordProvider(client: BackendProcessClient(executableURL: executable))
        provider.authorizeFolders = { folders in
            folders.map(\.standardizedFileURL.path) == [directory.path]
        }

        let records = try await provider.records(connection: connection, directory: directory, mappings: [])
        #expect(records.count == 5)
        #expect(records.allSatisfy { $0.sourcePath == source.path && $0.sourceRevision == sourceRevision })
        #expect(records.allSatisfy { $0.dataType.isEmpty })

        let flowByReach = records.filter { $0.parts.count == 6 && $0.parts[2] == "Flow" }
        #expect(flowByReach.count == 2)
        #expect(Set(flowByReach.map(\.path)).count == 2)
        let condensedFlow = try #require(flowByReach.first { $0.parts[1] == "Reach-A" })
        #expect(condensedFlow.comprisingPaths == [
            "/Round28/Reach-A/Flow/01Dec2024/1Hour/Round28/",
            "/Round28/Reach-A/Flow/01Jan2025/1Hour/Round28/"
        ])
        #expect(condensedFlow.parts[3] == "01Dec2024-01Jan2025")

        let results = try await provider.read(DSSRecordReadRequest(
            sourcePath: source.path, sourceRevision: sourceRevision, recordPaths: records.map(\.path)))
        #expect(results.count == records.count)
        #expect(results.map(\.path) == records.map(\.path))
        #expect(results.filter { $0.kind == "location" }.count == 1)

        let flow = try #require(results.first { $0.path == condensedFlow.path })
        #expect(flow.kind == "timeSeries")
        #expect(flow.recordType == condensedFlow.recordType)
        #expect(flow.timeSeries?.times.count == 28)
        #expect(flow.timeSeries?.times.first == "2024-12-31T22:00:00.0000000")
        #expect(flow.timeSeries?.values[7] == nil)
        #expect(flow.timeSeries?.qualities == Array(10...37))
        #expect(flow.timeSeries?.units == "CFS")
        #expect(flow.timeSeries?.dataType == "INST-VAL")

        let stageRecord = try #require(records.first { $0.parts.count == 6 && $0.parts[2] == "Stage" })
        let stage = try #require(results.first { $0.path == stageRecord.path })
        #expect(stage.kind == "timeSeries")
        #expect(stage.timeSeries?.times == [
            "2024-12-31T23:59:40.0000000",
            "2024-12-31T23:59:47.0000000",
            "2025-01-01T00:00:35.0000000",
            "2025-01-01T00:00:41.0000000",
            "2025-01-01T00:01:10.0000000"
        ])
        #expect(stage.timeSeries?.values == [2.5, 4.5, nil, 8.5, 10.5])
        #expect(stage.timeSeries?.values[2] == nil)
        #expect(stage.timeSeries?.qualities == Array(31...35))

        let pairedRecord = try #require(records.first { $0.parts.count == 6 && $0.parts[2] == "Rating" })
        let paired = try #require(results.first { $0.path == pairedRecord.path })
        #expect(paired.kind == "pairedData")
        #expect(paired.pairedData?.ordinates == [0, 5, 10])
        #expect(paired.pairedData?.curves.map(\.label) == ["Low Flow", "High Flow"])
        #expect(paired.pairedData?.curves.map(\.values.count) == [3, 3])
        #expect(paired.pairedData?.independentUnits == "FT")
        #expect(paired.pairedData?.dependentUnits == "CFS")
        #expect(paired.location?.x == 500_123.25)
        #expect(paired.location?.y == 3_765_432.75)
        #expect(paired.location?.z == 18.5)
        #expect(paired.location?.coordinateSystem == "UTM")
        #expect(paired.location?.coordinateID == 26_910)
        #expect(paired.location?.horizontalUnits == 3)
        #expect(paired.location?.horizontalDatum == 4)
        #expect(paired.location?.verticalUnits == 5)
        #expect(paired.location?.verticalDatum == 6)
        #expect(paired.location?.timeZoneName == "America/Los_Angeles")
        #expect(paired.location?.supplemental == "round28-position-fields")

        #expect(try Data(contentsOf: source) == originalBytes)
    }
}
