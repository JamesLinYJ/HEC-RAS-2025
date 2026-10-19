import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendBoundarySeriesTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BOUNDARY_SERIES_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func actualSourceSeriesDraftsRemainSeparateAndSaveRealValues() async throws {
        let (folder, document, provider) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let asset = try #require(document.assets.first { $0.section == .boundaryConditions })
        let original = try Data(contentsOf: asset.url), a = ModelEditorSession(provider: provider), b = ModelEditorSession(provider: provider)
        await a.load(asset, kind: .boundaryCondition); await b.load(asset, kind: .boundaryCondition)
        #expect(a.loaded && b.loaded && a.error == nil && b.error == nil)
        let line = try #require(a.boundaryLines?.lines.first), payload = try #require(line.payloads.first), page = try #require(payload.page)
        let otherLine = try #require(b.boundaryLines?.lines.first), otherPayload = try #require(otherLine.payloads.first), otherPage = try #require(otherPayload.page)
        #expect(payload.name == "同名载荷" && payload.id != otherPayload.id)
        let secondDuplicate = try #require(a.boundaryLines?.lines.last?.payloads.first)
        #expect(payload.name == secondDuplicate.name && payload.id != secondDuplicate.id)
        #expect(a.samples[page.id]?[1].y.isNaN == true)
        #expect(await a.editSeries(pageID: page.id, operation: .interpolate))
        #expect(a.samples[page.id]?[1].y == 3 && a.modified)
        #expect(b.samples[otherPage.id]?[1].y.isNaN == true)
        #expect(try Data(contentsOf: asset.url) == original)
        let sample = try #require(a.samples[page.id]?.first)
        let originalX = sample.x
        a.setSample(page: page.id, id: sample.id, x: originalX + 100, datasetID: sample.datasetKey)
        #expect(a.samples[page.id]?.first?.x == originalX)
        #expect(await a.saveLoadedModel())
        #expect(!a.modified && a.boundaryLines?.lines.first?.id == line.id && a.samples[page.id]?[1].y == 3)
        let fresh = try await provider.load(asset, kind: .boundaryCondition)
        let reopenedPage = try #require(fresh.boundaryLines?.lines.first?.payloads.first?.page)
        #expect(fresh.samples[reopenedPage.id]?[1].y == 3)
        #expect(await b.editSeries(pageID: otherPage.id, operation: .clear) == false)
        #expect(b.error != nil && b.samples[otherPage.id]?[1].y.isNaN == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BOUNDARY_SERIES_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func actualStationTableEditsAndNewStationsPersistWithoutPlotOverwrite() async throws {
        let (folder, document, provider) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let asset = try #require(document.assets.first { $0.section == .boundaryConditions }), editor = ModelEditorSession(provider: provider)
        await editor.load(asset, kind: .boundaryCondition)
        let payload = try #require(editor.boundaryLines?.lines.first(where: { $0.name == "空间变化边界" })?.payloads.first), page = try #require(payload.page)
        let table = try #require(editor.seriesPresentations[page.id]?.tableID)
        let selectedLine = try #require(editor.boundaryLines?.lines.first(where: { $0.name == "空间变化边界" }))
        editor.selectBoundaryLine(selectedLine.id); editor.selectBoundaryPayload(payload.id, lineID: selectedLine.id)
        editor.setCell(table: table, rowID: "0", column: "station/0", value: "42")
        #expect(await editor.editSeries(pageID: page.id, operation: .refresh))
        #expect(editor.samples[page.id]?.first(where: { $0.datasetKey.hasSuffix("/station/0") })?.y == 42)
        #expect(await editor.editSeries(pageID: page.id, operation: .addStation))
        let stationTable = try #require(editor.seriesPresentations[page.id]?.stationTableID)
        #expect(editor.rows[stationTable]?.count == 4)
        editor.setCell(table: stationTable, rowID: "station/3", column: "Station", value: "15")
        editor.setCell(table: table, rowID: "0", column: "station/3", value: "9.5")
        #expect(await editor.saveLoadedModel())
        #expect(editor.selectedBoundaryLineID == selectedLine.id && editor.selectedBoundaryPayloadIDs[selectedLine.id] == payload.id)
        let fresh = try await provider.load(asset, kind: .boundaryCondition)
        let reopened = try #require(fresh.boundaryLines?.lines.first(where: { $0.name == "空间变化边界" })?.payloads.first?.page)
        let description = try #require(fresh.seriesPresentations[reopened.id]), reopenedTable = try #require(description.tableID), stations = try #require(description.stationTableID)
        #expect(fresh.rows[stations]?.last?.values["Station"] == "15")
        #expect(fresh.rows[reopenedTable]?.first?.values["station/0"] == "42")
        #expect(fresh.rows[reopenedTable]?.first?.values["station/3"] == "9.5")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BOUNDARY_SERIES_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func actualClearAllowsRefillingMissingValuesAndIntervalPreviewDoesNotSave() async throws {
        let (folder, document, provider) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let asset = try #require(document.assets.first { $0.section == .boundaryConditions }), editor = ModelEditorSession(provider: provider)
        await editor.load(asset, kind: .boundaryCondition)
        let payload = try #require(editor.boundaryLines?.lines.first?.payloads.first), page = try #require(payload.page)
        let original = try Data(contentsOf: asset.url)
        #expect(await editor.editSeries(pageID: page.id, operation: .clear))
        #expect(editor.samples[page.id]?.allSatisfy { $0.y.isNaN } == true)
        let missing = try #require(editor.samples[page.id]?.first)
        editor.setSample(page: page.id, id: missing.id, y: 7, datasetID: missing.datasetKey)
        let interval = payload.scope + "/RegularTimeSeriesPayloadEditor/TimeSeriesDefinition_Interval"
        editor.set(interval, "900")
        #expect(await editor.editSeries(pageID: page.id, operation: .refresh))
        #expect(editor.samples[page.id]?.first?.y == 7)
        let values = try #require(editor.samples[page.id]); #expect(values[1].x - values[0].x == 900)
        #expect(try Data(contentsOf: asset.url) == original)
        #expect(await editor.saveLoadedModel())
        let fresh = try await provider.load(asset, kind: .boundaryCondition), reopened = try #require(fresh.boundaryLines?.lines.first?.payloads.first?.page)
        #expect(fresh.samples[reopened.id]?.first?.y == 7 && fresh.samples[reopened.id]?[1].y.isNaN == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BOUNDARY_SERIES_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func laterEditsUseTheNewSourceRevisionAndCanBeSavedAfterAnEarlierSave() async throws {
        let (folder, document, provider) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let asset = try #require(document.assets.first { $0.section == .boundaryConditions }), editor = ModelEditorSession(provider: provider)
        await editor.load(asset, kind: .boundaryCondition)
        let field = "BoundaryConditionsSummary/BoundaryCondition_Description"
        editor.set(field, "先保存的说明")
        let save = Task { await editor.saveLoadedModel() }
        let deadline = Date().addingTimeInterval(5)
        while !editor.isSaving, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(editor.isSaving)
        editor.set(field, "保存过程中继续输入的说明")
        #expect(await save.value == false && editor.modified)
        #expect(await editor.saveLoadedModel())
        let actual = try await provider.load(asset, kind: .boundaryCondition)
        #expect(actual.fields[field] == "保存过程中继续输入的说明" && !editor.modified)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BOUNDARY_SERIES_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func previewKeepsFloatingStartSemanticsAndDiscardDropsStationDraftState() async throws {
        let (folder, document, provider) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let asset = try #require(document.assets.first { $0.section == .boundaryConditions }), editor = ModelEditorSession(provider: provider)
        await editor.load(asset, kind: .boundaryCondition)
        let spatial = try #require(editor.boundaryLines?.lines.first(where: { $0.name == "空间变化边界" })?.payloads.first?.page)
        #expect(await editor.editSeries(pageID: spatial.id, operation: .addStation))
        let stations = try #require(editor.seriesPresentations[spatial.id]?.stationTableID)
        #expect(editor.rows[stations]?.count == 4)
        editor.discardEdits()
        #expect(editor.rows[stations]?.count == 3 && !editor.modified)
        let payload = try #require(editor.boundaryLines?.lines.first?.payloads.first), page = try #require(payload.page)
        editor.set("BoundaryConditionsSummary/BoundaryCondition_StartTime", "2026-10-15T09:00:00+08:00")
        editor.set("BoundaryConditionsSummary/BoundaryCondition_EndTime", "2026-10-15T10:00:00+08:00")
        #expect(await editor.editSeries(pageID: page.id, operation: .refresh))
        #expect(await editor.saveLoadedModel(), "\(editor.error ?? "no source error")")
        let actual = try await provider.load(asset, kind: .boundaryCondition)
        let refreshed = try #require(actual.boundaryLines?.lines.first?.payloads.first)
        #expect(actual.fields[refreshed.scope + "/RegularTimeSeriesPayloadEditor/TimeSeriesDefinition_UseFixedStartTime"] == "false")
        let sourceSpatial = try #require(actual.boundaryLines?.lines.first(where: { $0.name == "空间变化边界" })?.payloads.first?.page)
        let table = try #require(actual.seriesPresentations[sourceSpatial.id]?.stationTableID)
        #expect(actual.rows[table]?.count == 3)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BOUNDARY_SERIES_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func payloadCreationDeletionAndDiscardPreserveDraftsUntilExplicitSave() async throws {
        let (folder, document, provider) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let asset = try #require(document.assets.first { $0.section == .boundaryConditions }), editor = ModelEditorSession(provider: provider)
        await editor.load(asset, kind: .boundaryCondition)
        let projectURL = try #require(document.url)
        let original = try Data(contentsOf: asset.url), projectBytes = try Data(contentsOf: projectURL)
        let line = try #require(editor.boundaryLines?.lines.first), originalIDs = line.payloads.map(\.id)
        let description = "BoundaryConditionsSummary/BoundaryCondition_Description"
        editor.set(description, "创建前未保存的说明")
        var fields = try #require(line.newPayload?.fields)
        fields["NewPayloadPage/ViewModel_HydraulicDataType"] = "Constant"
        fields["NewPayloadPage/ViewModel_PayloadName"] = "中文新增载荷"
        fields["NewPayloadPage/ViewModel_HydraulicConstantValue"] = "12.5"
        #expect(await editor.perform(.createBoundaryPayload(lineID: line.id, fields: fields)), "\(editor.error ?? "no error")")
        let created = try #require(editor.selectedBoundaryPayload)
        #expect(created.name == "中文新增载荷" && !originalIDs.contains(created.id) && editor.modified)
        #expect(editor.fields[description] == "创建前未保存的说明")
        #expect(try Data(contentsOf: asset.url) == original)
        editor.discardEdits()
        #expect(editor.boundaryLines?.lines.first?.payloads.map(\.id) == originalIDs && !editor.modified)
        #expect(editor.fields[description] != "创建前未保存的说明")
        #expect(await editor.perform(.createBoundaryPayload(lineID: line.id, fields: fields)))
        let replacement = try #require(editor.selectedBoundaryPayload)
        #expect(replacement.id != created.id)
        editor.set(replacement.scope + "/PayloadDetails/Description", "中文载荷说明")
        #expect(await editor.saveLoadedModel(), "\(editor.error ?? "no error")")
        let saved = try Data(contentsOf: asset.url)
        #expect(saved != original && !editor.modified && editor.selectedBoundaryPayload?.id == replacement.id)
        let actual = try await provider.load(asset, kind: .boundaryCondition)
        let actualPayload = try #require(actual.boundaryLines?.lines.first?.payloads.last)
        #expect(actualPayload.name == "中文新增载荷" && actual.fields[actualPayload.scope + "/ConstantPayloadEditor/ConstantPayload_Value"] == "12.5")
        #expect(actual.fields[actualPayload.scope + "/PayloadDetails/Description"] == "中文载荷说明")
        #expect(await editor.perform(.removeBoundaryPayload(lineID: line.id, payloadID: replacement.id)))
        #expect(editor.modified && editor.boundaryLines?.lines.first?.payloads.count == originalIDs.count)
        #expect(try Data(contentsOf: asset.url) == saved)
        editor.discardEdits()
        #expect(editor.boundaryLines?.lines.first?.payloads.contains(where: { $0.id == replacement.id }) == true && !editor.modified)
        #expect(await editor.perform(.removeBoundaryPayload(lineID: line.id, payloadID: replacement.id)))
        #expect(await editor.saveLoadedModel())
        let removed = try await provider.load(asset, kind: .boundaryCondition)
        #expect(removed.boundaryLines?.lines.first?.payloads.count == originalIDs.count)
        #expect(try Data(contentsOf: projectURL) == projectBytes)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BOUNDARY_SERIES_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func emptyIrregularPayloadAcceptsRowsAndARejectedConstructorKeepsTheCurrentDraft() async throws {
        let (folder, document, provider) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let asset = try #require(document.assets.first { $0.section == .boundaryConditions }), editor = ModelEditorSession(provider: provider)
        await editor.load(asset, kind: .boundaryCondition)
        let original = try Data(contentsOf: asset.url), line = try #require(editor.boundaryLines?.lines.last)
        var fields = try #require(line.newPayload?.fields)
        fields["NewPayloadPage/ViewModel_HydraulicDataType"] = "Functional"
        editor.set("BoundaryConditionsSummary/BoundaryCondition_Description", "失败时保留的草稿")
        #expect(await editor.perform(.createBoundaryPayload(lineID: line.id, fields: fields)) == false)
        #expect(editor.error != nil && editor.modified && editor.fields["BoundaryConditionsSummary/BoundaryCondition_Description"] == "失败时保留的草稿")
        fields["NewPayloadPage/ViewModel_HydraulicDataType"] = "Tabular"
        fields["NewPayloadPage/ViewModel_TimeSeriesType"] = "Irregular"
        fields["NewPayloadPage/ViewModel_PayloadName"] = "新的不规则序列"
        #expect(await editor.perform(.createBoundaryPayload(lineID: line.id, fields: fields)))
        let payload = try #require(editor.selectedBoundaryPayload), page = try #require(payload.page)
        #expect(editor.samples[page.id]?.isEmpty == true && editor.error == nil)
        #expect(await editor.editSeries(pageID: page.id, operation: .appendRow))
        let first = try #require(editor.samples[page.id]?.first)
        editor.setSample(page: page.id, id: first.id, x: first.x + 15, y: 8, datasetID: first.datasetKey)
        #expect(await editor.editSeries(pageID: page.id, operation: .appendRow))
        #expect(editor.samples[page.id]?.count == 2 && editor.samples[page.id]?.first?.y == 8)
        #expect(await editor.editSeries(pageID: page.id, operation: .removeLastRow))
        #expect(editor.samples[page.id]?.count == 1)
        #expect(try Data(contentsOf: asset.url) == original)
        #expect(await editor.saveLoadedModel(), "\(editor.error ?? "no error")")
        let actual = try await provider.load(asset, kind: .boundaryCondition)
        let reopened = try #require(actual.boundaryLines?.lines.last?.payloads.last?.page)
        #expect(actual.samples[reopened.id]?.count == 1 && actual.samples[reopened.id]?.first?.y == 8 && actual.samples[reopened.id]?.first?.x == first.x + 15)
        #expect(editor.selectedBoundaryLineID == line.id && !editor.modified)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BOUNDARY_SERIES_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func reapplyingMountedControlValuesDoesNotCreateAnUnsavedDraft() async throws {
        let (folder, document, provider) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let asset = try #require(document.assets.first { $0.section == .boundaryConditions }), editor = ModelEditorSession(provider: provider)
        await editor.load(asset, kind: .boundaryCondition)
        let description = "BoundaryConditionsSummary/BoundaryCondition_Description"
        editor.set(description, editor.fields[description] ?? "")
        let page = try #require(editor.boundaryLines?.lines.first?.payloads.first?.page)
        let sample = try #require(editor.samples[page.id]?[1])
        editor.setSample(page: page.id, id: sample.id, y: sample.y, datasetID: sample.datasetKey)
        let spatial = try #require(editor.boundaryLines?.lines[1].payloads.first?.page)
        let table = try #require(editor.seriesPresentations[spatial.id]?.tableID), row = try #require(editor.rows[table]?.first)
        editor.setCell(table: table, rowID: row.id, column: "station/0", value: row.values["station/0"] ?? "")
        #expect(!editor.modified && editor.error == nil)
    }

    @MainActor private func setup() throws -> (URL, ProjectDocument, BackendModelProvider) {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_BOUNDARY_SERIES_ACCEPTANCE_DIRECTORY"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("boundary-series-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: folder)
        let document = try ProjectDocument(contentsOf: folder.appendingPathComponent("时间序列.ras"))
        let provider = BackendModelProvider(client: .init(executableURL: URL(fileURLWithPath: executable)))
        provider.setProject(document)
        return (folder, document, provider)
    }
}
