import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendSpatialPointTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_SPATIAL_POINT_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func actualSharedStationsAndTableEditsSaveAndRejectStaleDrafts() async throws {
        let (folder, document, provider) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let asset = try #require(document.assets.first { $0.section == .boundaryConditions })
        let original = try Data(contentsOf: asset.url), editor = ModelEditorSession(provider: provider), other = ModelEditorSession(provider: provider)
        await editor.load(asset, kind: .boundaryCondition); await other.load(asset, kind: .boundaryCondition)
        #expect(editor.loaded && editor.error == nil)
        let data = try #require(editor.spatialPresentations["precipitation"]?.pointData), station = try #require(data.stations.first)
        let wind = try #require(editor.spatialPresentations["wind"]?.pointData)
        #expect(data.stations.first?.id == wind.stations.first?.id && wind.unit == "m/s")
        let page = try #require(data.inputs.first?.pageId), table = try #require(editor.seriesPresentations[page]?.tableID)
        #expect(editor.seriesPresentations[page]?.stationTableID == nil)
        editor.set(station.scope + "/Name", "Swift 中文站点")
        editor.set(station.scope + "/ElevationOffGround", "4.25")
        editor.setCell(table: table, rowID: "1", column: "Value", value: "12.5")
        #expect(await editor.perform(.editSpatial(layerID: "wind", operation: "addStation", itemID: nil)))
        #expect(editor.spatialPresentations["wind"]?.pointData?.stations.count == 2)
        #expect(editor.fields[station.scope + "/Name"] == "Swift 中文站点" && editor.rows[table]?[1].values["Value"] == "12.5")
        #expect(try Data(contentsOf: asset.url) == original)
        #expect(await editor.saveLoadedModel())
        #expect(!editor.modified && editor.error == nil)
        #expect(editor.spatialPresentations["wind"]?.pointData?.stations.first?.id == station.id)
        let fresh = try await provider.load(asset, kind: .boundaryCondition)
        let reopened = try #require(fresh.spatialPresentations["precipitation"]?.pointData), reopenedStation = try #require(reopened.stations.first)
        let reopenedPage = try #require(reopened.inputs.first?.pageId), reopenedTable = try #require(fresh.seriesPresentations[reopenedPage]?.tableID)
        #expect(fresh.fields[reopenedStation.scope + "/Name"] == "Swift 中文站点" && fresh.fields[reopenedStation.scope + "/ElevationOffGround"] == "4.25")
        #expect(fresh.rows[reopenedTable]?[1].values["Value"] == "12.5")
        #expect(await other.perform(.editSpatial(layerID: "wind", operation: "addStation", itemID: nil)) == false)
        #expect(other.error != nil && other.spatialPresentations["wind"]?.pointData?.stations.count == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_SPATIAL_POINT_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func sourceInputCreationAbsoluteRowsAndSharedDeletionRemainDrafts() async throws {
        let (folder, document, provider) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let asset = try #require(document.assets.first { $0.section == .boundaryConditions }), editor = ModelEditorSession(provider: provider)
        let original = try Data(contentsOf: asset.url)
        await editor.load(asset, kind: .boundaryCondition)
        let station = try #require(editor.spatialPresentations["airDensity"]?.pointData?.stations.first)
        #expect(await editor.perform(.editSpatial(layerID: "airDensity", operation: "addGauge", itemID: station.id)))
        let input = try #require(editor.spatialPresentations["airDensity"]?.pointData?.inputs.last)
        editor.set(input.scope + "/LocalDataType", "Table")
        editor.set(input.scope + "/TimeSeriesType", "Irregular")
        editor.set(input.scope + "/ExpressedTimeType", "Absolute")
        #expect(await editor.perform(.editSpatial(layerID: "airDensity", operation: "refresh", itemID: nil)))
        let page = try #require(editor.spatialPresentations["airDensity"]?.pointData?.inputs.last?.pageId)
        #expect(await editor.editSeries(pageID: page, operation: .appendRow))
        let table = try #require(editor.seriesPresentations[page]?.tableID)
        editor.setCell(table: table, rowID: "0", column: "Value", value: "1.125")
        #expect(try Data(contentsOf: asset.url) == original)
        try #require(await editor.saveLoadedModel(), Comment(rawValue: editor.error ?? "Save failed"))
        let saved = try Data(contentsOf: asset.url)
        #expect(editor.rows[table]?.first?.values["Value"] == "1.125")
        #expect(await editor.perform(.editSpatial(layerID: "precipitation", operation: "removeStation", itemID: station.id)))
        #expect(editor.spatialPresentations.values.allSatisfy { $0.pointData?.inputs.allSatisfy { $0.stationId != station.id } ?? false })
        #expect(try Data(contentsOf: asset.url) == saved)
        editor.discardEdits()
        #expect(!editor.modified && editor.spatialPresentations["airDensity"]?.pointData?.inputs.last?.stationId == station.id)
        #expect(await editor.perform(.editSpatial(layerID: "airDensity", operation: "removeGauge", itemID: input.id)))
        #expect(await editor.saveLoadedModel())
        let fresh = try await provider.load(asset, kind: .boundaryCondition)
        #expect(fresh.spatialPresentations["airDensity"]?.pointData?.inputs.isEmpty == true)
        #expect(fresh.spatialPresentations["precipitation"]?.pointData?.stations.count == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_SPATIAL_POINT_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func displayUnitsPreserveCanonicalDraftAndConvertedEditsSaveSourceValues() async throws {
        let (folder, document, provider) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let asset = try #require(document.assets.first { $0.section == .boundaryConditions }), editor = ModelEditorSession(provider: provider)
        let original = try Data(contentsOf: asset.url)
        await editor.load(asset, kind: .boundaryCondition)
        let data = try #require(editor.spatialPresentations["wind"]?.pointData), units = try #require(data.valueUnits)
        let station = try #require(data.stations.first), heightUnits = try #require(data.heightUnits)
        let page = try #require(data.inputs.first?.pageId), table = try #require(editor.seriesPresentations[page]?.tableID)
        let originalRows = editor.rows[table]?.map(\.values), originalSamples = editor.samples[page]?.map { $0.y.bitPattern }
        editor.selectDisplayUnit("ft/s", units: units); editor.selectDisplayUnit("ft", units: heightUnits)
        #expect(!editor.modified && editor.rows[table]?.map(\.values) == originalRows && editor.samples[page]?.map { $0.y.bitPattern } == originalSamples)
        #expect(try Data(contentsOf: asset.url) == original)
        let speed = try #require(editor.displayUnit(units)), height = try #require(editor.displayUnit(heightUnits))
        #expect(speed.id == "ft/s" && height.id == "ft")
        let raw = try #require(editor.rows[table]?[0].values["Value"]), source = try #require(Double(raw))
        if let repeated = speed.edited(speed.displayed(source), previous: raw) { editor.setCell(table: table, rowID: "0", column: "Value", value: repeated) }
        #expect(!editor.modified)
        let changed = try #require(speed.edited(10, previous: raw))
        editor.setCell(table: table, rowID: "0", column: "Value", value: changed)
        let actualHeight = try #require(height.edited(20, previous: "")); editor.set(station.scope + "/ElevationOffGround", actualHeight)
        let pressure = try #require(editor.spatialPresentations["airPressure"]?.pointData?.valueUnits)
        editor.selectDisplayUnit("Pa", units: pressure)
        let pa = try #require(editor.displayUnit(pressure)), pressureField = "AirPressureControl/AirPressureLayer_ConstantValue"
        let actualPressure = try #require(pa.edited(100000, previous: editor.fields[pressureField] ?? "")); editor.set(pressureField, actualPressure)
        #expect(try Data(contentsOf: asset.url) == original)
        try #require(await editor.saveLoadedModel(), Comment(rawValue: editor.error ?? "Save failed"))
        #expect(editor.displayUnit(units)?.id == "ft/s" && !editor.modified)
        let fresh = try await provider.load(asset, kind: .boundaryCondition), reopened = try #require(fresh.spatialPresentations["wind"]?.pointData)
        let reopenedPage = try #require(reopened.inputs.first?.pageId), reopenedTable = try #require(fresh.seriesPresentations[reopenedPage]?.tableID)
        let savedSpeed = try #require(Double(fresh.rows[reopenedTable]?[0].values["Value"] ?? ""))
        #expect(abs(savedSpeed - 3.048) < 1e-12)
        let savedStation = try #require(reopened.stations.first)
        #expect(abs((Double(fresh.fields[savedStation.scope + "/ElevationOffGround"] ?? "") ?? .nan) - 6.096) < 1e-6)
        #expect(Double(fresh.fields[pressureField] ?? "") == 1000)
        #expect(fresh.seriesPresentations[reopenedPage]?.valueUnits?.sourceId == "m/s")
    }

    @Test func malformedUnitMetadataCannotChangeMeasurementMeaning() throws {
        let input = Data(#"{"sourceId":"m/s","selectionId":"wind","choices":[{"id":"m/s","scale":1,"offset":0},{"id":"ft/s","scale":0,"offset":0}]}"#.utf8)
        let units = try JSONDecoder().decode(DisplayUnitData.self, from: input)
        #expect(throws: Error.self) { try units.validate() }
    }

    @Test func fractionalSourceTimestampRemainsParseableByNativeDateControls() throws {
        let value = try #require(SourceTimestamp.parse("2026-10-16T08:00:00.1250000+08:00"))
        let expected = try #require(SourceTimestamp.parse("2026-10-16T00:00:00Z"))
        #expect(abs(value.timeIntervalSince(expected) - 0.125) < 0.000001)
    }

    @MainActor private func setup() throws -> (URL, ProjectDocument, BackendModelProvider) {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_SPATIAL_POINT_ACCEPTANCE_DIRECTORY"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("spatial-point-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: folder)
        let document = try ProjectDocument(contentsOf: folder.appendingPathComponent("站点编辑.ras"))
        let provider = BackendModelProvider(client: .init(executableURL: URL(fileURLWithPath: executable)))
        provider.setProject(document)
        return (folder, document, provider)
    }
}
