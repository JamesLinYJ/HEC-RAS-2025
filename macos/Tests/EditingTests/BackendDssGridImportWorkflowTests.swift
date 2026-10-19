import CryptoKit
import Foundation
import Testing
import RASWorkspaceCore
@testable import HECRAS2025

struct BackendDssGridImportWorkflowTests {
    @Test
    func spatialGridWallClockAndExplicitOffsetsKeepTheirOwnTimeMeaning() throws {
        let wallTime = "2025-01-01T00:00:00.0000000"
        let wallDate = try #require(SpatialGridTimestamp.parse(wallTime))
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = .current
        let wallComponents = localCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: wallDate)
        #expect(wallComponents.year == 2025 && wallComponents.month == 1 && wallComponents.day == 1)
        #expect(wallComponents.hour == 0 && wallComponents.minute == 0 && wallComponents.second == 0)

        let utcTime = "2025-01-01T00:00:00.0000000Z"
        let utcDate = try #require(SpatialGridTimestamp.parse(utcTime))
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let utcComponents = utcCalendar.dateComponents([.year, .month, .day, .hour], from: utcDate)
        #expect(utcComponents.year == 2025 && utcComponents.month == 1 && utcComponents.day == 1 && utcComponents.hour == 0)

        let offsetTime = "2025-01-01T00:00:00.0000000+08:00"
        let offsetDate = try #require(SpatialGridTimestamp.parse(offsetTime))
        let equivalentUtcDate = try #require(SpatialGridTimestamp.parse("2024-12-31T16:00:00.0000000Z"))
        #expect(offsetDate == equivalentUtcDate,
            "An explicit offset remains an instant; only an unqualified DSS time is interpreted as local wall-clock time.")

        let data = SpatialGridData(layerId: "airPressure", times: [wallTime], components: ["Value"],
            units: "mb", projection: "", rows: 1, columns: 1, selectedTimeId: nil,
            selectedComponent: nil, preview: nil, error: nil)
        let step = try #require(data.presentation().timeSteps.first)
        #expect(step.id == "Value|\(wallTime)", "The canonical wall-time string remains the stable selection ID.")
        #expect(step.date == wallDate)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_DSS_GRID_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func realPublishedHostImportsDssFramesThroughDuplexAndReadsSavedBoundaryFrames() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixturePath = try #require(environment["HECRAS_DSS_GRID_ACCEPTANCE_DIRECTORY"])
        let executablePath = try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dss-grid-duplex-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixturePath), to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        let projectURL = folder.appendingPathComponent("DSS栅格回归.ras")
        let projectBytes = try Data(contentsOf: projectURL)
        let sourceURL = folder.appendingPathComponent("真实DSS栅格序列.dss")
        let sourceBytes = try Data(contentsOf: sourceURL)
        let sourceRevision = Self.sha256(sourceBytes)
        let document = try ProjectDocument(contentsOf: projectURL)
        let asset = try #require(document.assets.first { $0.section == .boundaryConditions })
        let boundaryBeforeImport = try Data(contentsOf: asset.url)
        let provider = BackendModelProvider(client: BackendProcessClient(executableURL: URL(fileURLWithPath: executablePath)))
        provider.setProject(document)
        let editor = ModelEditorSession(provider: provider)
        await editor.load(asset, kind: .boundaryCondition)
        #expect(editor.loaded && editor.error == nil)
        let descriptionField = "BoundaryConditionsSummary/BoundaryCondition_Description"
        editor.set(descriptionField, "DSS duplex boundary draft saved with actual grid frames")

        let inspection = try await editor.inspectGrid(layerID: "airPressure", files: [sourceURL],
            subdataset: nil, bands: [], previewID: nil)
        let pressure = try #require(inspection.dssGridSources?.first {
            $0.recordPaths.count == 2 && $0.recordPaths.allSatisfy {
                Self.isDssRecord($0, bPart: "Pressure")
            }
        })
        #expect(pressure.times.count == 2 && pressure.recordPaths.count == 2)
        #expect(pressure.times[0].hasPrefix("2025-01-01") && pressure.times[1].hasPrefix("2025-01-02"))
        #expect(pressure.units == "Pa" && pressure.dataType == "INST_VAL")
        #expect(pressure.rows == 4 && pressure.columns == 4 && pressure.noDataValue == -9999)
        #expect(pressure.recordPaths.allSatisfy { Self.isDssRecord($0, bPart: "Pressure") })
        #expect(inspection.dssGridRevision == sourceRevision)
        #expect(try Data(contentsOf: sourceURL) == sourceBytes)

        let sourcePath = try #require(inspection.dssGridSourcePath)
        let draftIdentity = try #require(inspection.dssGridDraftIdentity)
        let component = DssGridImportComponent(component: "Value", seriesId: pressure.id,
            times: pressure.times, recordPaths: pressure.recordPaths, gridIdentity: pressure.gridIdentity)
        let dssSelection = DssGridImportSelection(sourcePath: sourcePath, revision: sourceRevision,
            draftIdentity: draftIdentity, operationId: UUID().uuidString.lowercased(), components: [component])
        let selection = SpatialGridSelection(layerId: "airPressure", bands: [], units: "Pa",
            dataType: "inst-val", dssSource: dssSelection)
        let progress = DssGridImportProgressRecorder()
        let saved = await editor.importGrid(selection,
            progress: { update in progress.updates.append(update) },
            cancellationAvailable: { progress.cancellationHandler = $0 })
        #expect(saved && editor.error == nil && !editor.modified)
        #expect(progress.updates.count >= 2, "The published backend should stream frame progress through the duplex route.")
        #expect(editor.fields[descriptionField] == "DSS duplex boundary draft saved with actual grid frames")
        #expect(try Data(contentsOf: sourceURL) == sourceBytes)
        #expect(try Data(contentsOf: projectURL) == projectBytes)

        let committedBoundary = try Data(contentsOf: asset.url)
        let committedRevision = Self.sha256(committedBoundary)
        #expect(committedBoundary != boundaryBeforeImport)
        #expect(editor.sourceFileRevision == committedRevision)
        let imported = try #require(editor.spatialPresentations["airPressure"]?.gridData)
        #expect(imported.times == pressure.times)
        #expect(imported.components == ["Value"])
        #expect(imported.projection.localizedCaseInsensitiveContains("Albers"))

        for (index, time) in pressure.times.enumerated() {
            let stepID = "Value|" + time
            let step = try #require(editor.spatialPresentations["airPressure"]?.timeSteps.first { $0.id == stepID })
            #expect(await editor.perform(.selectSpatialTime(layerID: "airPressure", stepID: step.id)))
            let preview = try #require(editor.spatialPresentations["airPressure"]?.gridData?.preview)
            let expected = index == 0 ? 1000.0 : 1010.0
            #expect(preview.minimum == expected && preview.maximum == expected)
            let validPixelCount = preview.rgba.enumerated().filter { $0.offset % 4 == 3 && $0.element > 0 }.count
            #expect(validPixelCount == (index == 0 ? 15 : 16),
                "The saved first frame must retain one NoData cell; the second frame must retain all DSS cells.")
        }
        #expect(editor.sourceFileRevision == committedRevision)

        // Request cancellation immediately after the actual duplex operation is
        // installed. Either the cancellation or publication may win the atomic
        // boundary; both outcomes must agree with the on-disk snapshot.
        let refreshedInspection = try await editor.inspectGrid(layerID: "airPressure", files: [sourceURL],
            subdataset: nil, bands: [], previewID: nil)
        let refreshedPressure = try #require(refreshedInspection.dssGridSources?.first {
            $0.id == pressure.id && $0.recordPaths.allSatisfy {
                Self.isDssRecord($0, bPart: "Pressure")
            }
        })
        let cancelSelection = DssGridImportSelection(
            sourcePath: try #require(refreshedInspection.dssGridSourcePath),
            revision: try #require(refreshedInspection.dssGridRevision),
            draftIdentity: try #require(refreshedInspection.dssGridDraftIdentity),
            operationId: UUID().uuidString.lowercased(),
            components: [DssGridImportComponent(component: "Value", seriesId: refreshedPressure.id,
                times: refreshedPressure.times, recordPaths: refreshedPressure.recordPaths,
                gridIdentity: refreshedPressure.gridIdentity)])
        let beforeCancel = try Data(contentsOf: asset.url)
        let cancelProgress = DssGridImportProgressRecorder()
        let cancelResult = await editor.importGrid(SpatialGridSelection(layerId: "airPressure", bands: [],
            units: "Pa", dataType: "inst-val", dssSource: cancelSelection),
            progress: { update in cancelProgress.updates.append(update) },
            cancellationAvailable: { handler in
                cancelProgress.cancellationHandler = handler
                if let handler { cancelProgress.cancellationAccepted = handler() }
            })
        #expect(cancelProgress.cancellationAccepted == true)
        let afterCancel = try Data(contentsOf: asset.url)
        if cancelResult {
            #expect(editor.sourceFileRevision == Self.sha256(afterCancel))
            #expect(editor.error == nil)
        } else {
            #expect(afterCancel == beforeCancel, "A precommit cancellation must leave the boundary HDF untouched.")
        }
        #expect(try Data(contentsOf: sourceURL) == sourceBytes)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    private static func isDssRecord(_ path: String, bPart: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        return parts.count == 6 && parts[0] == "RasTests" && parts[1] == bPart
            && parts[2] == "Surface" && parts[4] == "1Day" && parts[5] == "RasTests"
    }
}

@MainActor
private final class DssGridImportProgressRecorder {
    var updates: [BackendProgressUpdate] = []
    var cancellationHandler: GridImportCancelHandler?
    var cancellationAccepted: Bool?
}
