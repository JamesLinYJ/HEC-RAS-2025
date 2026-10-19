import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendBoundarySpatialTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_PLAN_EXPORT_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func actualSpatialControlsSaveSeparateLayerValuesAndWindComponents() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_PLAN_EXPORT_ACCEPTANCE_DIRECTORY"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spatial-controls-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try ProjectDocument(contentsOf: directory.appendingPathComponent("source/原工程.ras"))
        let provider = BackendModelProvider(client: .init(executableURL: URL(fileURLWithPath: executable)))
        provider.setProject(project)
        let asset = try #require(project.assets.first { $0.section == .boundaryConditions })
        let session = ModelEditorSession(provider: provider)
        await session.load(asset, kind: .boundaryCondition)
        #expect(session.loaded && session.canEdit && session.error == nil)
        let precipitation = "PrecipitationControl/PrecipitationLayer_", wind = "WindForcesControl/WindLayer_"
        let originalWind = try #require(session.fields[wind + "IsEnabled"])
        session.set(precipitation + "IsEnabled", "true")
        #expect(session.fields[wind + "IsEnabled"] == originalWind)
        session.set(precipitation + "SpatialDataType", "Constant"); session.set(precipitation + "ConstantValue", "0.005")
        session.set(wind + "IsEnabled", "true"); session.set(wind + "SpatialDataType", "Constant")
        session.set("WindConstantControl/Constant1", "-3.25"); session.set("WindConstantControl/Constant2", "2.5")
        #expect(await session.saveLoadedModel())
        #expect(!session.modified && session.error == nil)
        let reread = try await provider.load(asset, kind: .boundaryCondition)
        #expect(reread.fields[precipitation + "ConstantValue"] == "0.005")
        #expect(reread.fields[wind + "IsEnabled"] == "true")
        #expect(reread.fields["WindConstantControl/Constant1"] == "-3.25")
        #expect(reread.fields["WindConstantControl/Constant2"] == "2.5")
        #expect(reread.fields["AirPressureControl/AirPressureLayer_IsEnabled"] == "false")
        #expect(reread.fields["AirDensityControl/AirDensityLayer_IsEnabled"] == "false")
        let field = try #require(SourceEditorLibrary.shared.schema("WindConstantControl")?.fields.first)
        #expect(field.titled("X Wind Velocity").storageID == field.storageID)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_PLAN_EXPORT_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func windConstantComponentsConvertIndependentlySaveAsMetersPerSecondAndDiscardDrafts() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_PLAN_EXPORT_ACCEPTANCE_DIRECTORY"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wind-units-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let projectURL = directory.appendingPathComponent("source/原工程.ras")
        let project = try ProjectDocument(contentsOf: projectURL)
        let provider = BackendModelProvider(client: .init(executableURL: URL(fileURLWithPath: executable)))
        provider.setProject(project)
        let asset = try #require(project.assets.first { $0.section == .boundaryConditions })
        let vx = "WindConstantControl/Constant1", vy = "WindConstantControl/Constant2"
        let windLayer = "WindForcesControl/WindLayer_"

        // Establish finite source values in the disposable fixture copy so the
        // subsequent display edit and discard assertions have exact baselines.
        let seed = ModelEditorSession(provider: provider)
        await seed.load(asset, kind: .boundaryCondition)
        #expect(seed.loaded && seed.canEdit && seed.error == nil)
        seed.set(windLayer + "IsEnabled", "true")
        seed.set(windLayer + "SpatialDataType", "Constant")
        seed.set(vx, "2")
        seed.set(vy, "-1.5")
        #expect(abs((Double(seed.fields[vx] ?? "") ?? .nan) - 2) < 1e-12)
        #expect(abs((Double(seed.fields[vy] ?? "") ?? .nan) + 1.5) < 1e-12)
        if seed.modified { #expect(await seed.saveLoadedModel()) }
        #expect(!seed.modified && seed.error == nil)

        let originalAsset = try Data(contentsOf: asset.url)
        let originalProject = try Data(contentsOf: projectURL)
        let editor = ModelEditorSession(provider: provider)
        await editor.load(asset, kind: .boundaryCondition)
        #expect(editor.loaded && editor.canEdit && editor.error == nil)
        let units = try #require(editor.spatialPresentations["wind"]?.pointData?.valueUnits)
        #expect(units.sourceId == "m/s" && units.selectionId == "wind")
        #expect(units.sourceUnitTypeId?.isEmpty == false)
        let feetPerSecond = try #require(units.choices.first { $0.id == "ft/s" })
        #expect(feetPerSecond.name == "ft/s" && feetPerSecond.unitTypeId?.isEmpty == false)
        #expect(abs((Double(editor.fields[vx] ?? "") ?? .nan) - 2) < 1e-12)
        #expect(abs((Double(editor.fields[vy] ?? "") ?? .nan) + 1.5) < 1e-12)

        editor.selectDisplayUnit("ft/s", units: units)
        #expect(editor.displayUnit(units)?.id == "ft/s")
        let assetAfterSelection = try Data(contentsOf: asset.url)
        #expect(!editor.modified && assetAfterSelection == originalAsset)
        let xDraft = try #require(feetPerSecond.edited(10, previous: editor.fields[vx] ?? ""))
        editor.set(vx, xDraft)
        #expect(abs((Double(editor.fields[vx] ?? "") ?? .nan) - feetPerSecond.source(10)) < 1e-12)
        #expect(abs((Double(editor.fields[vy] ?? "") ?? .nan) + 1.5) < 1e-12)
        #expect(try Data(contentsOf: asset.url) == originalAsset)

        editor.discardEdits()
        #expect(!editor.modified)
        #expect(abs((Double(editor.fields[vx] ?? "") ?? .nan) - 2) < 1e-12)
        #expect(abs((Double(editor.fields[vy] ?? "") ?? .nan) + 1.5) < 1e-12)
        #expect(try Data(contentsOf: asset.url) == originalAsset)

        editor.selectDisplayUnit("ft/s", units: units)
        let savedX = try #require(feetPerSecond.edited(10, previous: editor.fields[vx] ?? ""))
        editor.set(vx, savedX)
        #expect(abs((Double(editor.fields[vy] ?? "") ?? .nan) + 1.5) < 1e-12)
        #expect(try Data(contentsOf: asset.url) == originalAsset)
        #expect(await editor.saveLoadedModel())
        #expect(!editor.modified && editor.error == nil)
        let afterXSave = try Data(contentsOf: asset.url)
        #expect(afterXSave != originalAsset)
        let afterX = try await provider.load(asset, kind: .boundaryCondition)
        #expect(abs((Double(afterX.fields[vx] ?? "") ?? .nan) - feetPerSecond.source(10)) < 1e-6)
        #expect(abs((Double(afterX.fields[vy] ?? "") ?? .nan) + 1.5) < 1e-6)

        let savedY = try #require(feetPerSecond.edited(-5, previous: editor.fields[vy] ?? ""))
        editor.set(vy, savedY)
        #expect(abs((Double(editor.fields[vx] ?? "") ?? .nan) - feetPerSecond.source(10)) < 1e-12)
        #expect(abs((Double(editor.fields[vy] ?? "") ?? .nan) - feetPerSecond.source(-5)) < 1e-12)
        #expect(try Data(contentsOf: asset.url) == afterXSave)
        #expect(await editor.saveLoadedModel())
        let afterY = try await provider.load(asset, kind: .boundaryCondition)
        #expect(abs((Double(afterY.fields[vx] ?? "") ?? .nan) - feetPerSecond.source(10)) < 1e-6)
        #expect(abs((Double(afterY.fields[vy] ?? "") ?? .nan) - feetPerSecond.source(-5)) < 1e-6)
        #expect(try Data(contentsOf: projectURL) == originalProject)
    }
}
