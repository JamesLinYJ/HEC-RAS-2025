import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class BoundaryPresentationProvider: ModelEditorProvider {
    var snapshot: EditorSnapshot
    var saves: [EditorEdits] = []
    init(_ snapshot: EditorSnapshot) { self.snapshot = snapshot }
    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot { snapshot }
    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws { saves.append(changes) }
    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot { snapshot }
}

struct BoundaryConditionTests {
    @Test @MainActor
    func spatialChoicesRespectSourceRestrictionsAndReadonlyModels() async throws {
        // EvapotranspirationControl exposes Constant/Point despite the shared
        // SpatialDataType enum also containing Gridded.
        let layer = SpatialBoundaryLayer.evapotranspiration
        let type = try #require(layer.typeField)
        let enabled = try #require(layer.enabledField)
        let provider = BoundaryPresentationProvider(.init(fields: [type.storageID: "Constant", enabled.storageID: "true"], rows: [:], samples: [:], canEdit: true, images: [:]))
        let session = ModelEditorSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/ui-fixture/boundary.h5"), section: .boundaryConditions)
        await session.load(asset, kind: .boundaryCondition)
        layer.selectType("Gridded", session: session)
        #expect(!session.modified)
        layer.selectType("Point", session: session)
        #expect(layer.selectedType(in: session.fields) == "Point")
        provider.snapshot.choiceOptions = [type.storageID: []]
        await session.load(asset, kind: .boundaryCondition)
        layer.selectType("Point", session: session)
        #expect(!session.modified)
        provider.snapshot.choiceOptions = [:]; provider.snapshot = .init(fields: provider.snapshot.fields, rows: [:], samples: [:], canEdit: false, images: [:])
        await session.load(asset, kind: .boundaryCondition)
        layer.setEnabled(false, session: session)
        layer.selectType("Point", session: session)
        #expect(!session.modified)
        #expect(layer.enabled(in: session.fields))
    }

    @Test @MainActor
    func spatialModeChangesKeepHiddenSourceValuesAndSaveOnlyEdits() async throws {
        let layer = SpatialBoundaryLayer.precipitation
        let type = try #require(layer.typeField)
        let enabled = try #require(layer.enabledField)
        let constant = try #require(layer.fields.first { $0.id.hasSuffix("_ConstantValue") })
        let original = [type.storageID: "Constant", enabled.storageID: "true", constant.storageID: "12.75", "OriginalSource/UnexposedSetting": "保留"]
        let provider = BoundaryPresentationProvider(.init(fields: original, rows: [:], samples: [:], canEdit: true, images: [:]))
        let session = ModelEditorSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/ui-fixture/boundary.h5"), section: .boundaryConditions)
        await session.load(asset, kind: .boundaryCondition)
        layer.selectType("Gridded", session: session); layer.setEnabled(false, session: session)
        #expect(!layer.contentFields(type: layer.selectedType(in: session.fields)).contains { $0.storageID == constant.storageID })
        #expect(session.fields[constant.storageID] == "12.75")
        #expect(session.fields["OriginalSource/UnexposedSetting"] == "保留")
        #expect(await session.save(asset))
        #expect(provider.saves.first?.fields == [type.storageID: "Gridded", enabled.storageID: "false"])
        layer.selectType("Constant", session: session); layer.setEnabled(true, session: session)
        #expect(session.fields[constant.storageID] == "12.75")
        session.discardEdits()
        #expect(layer.selectedType(in: session.fields) == "Gridded")
        #expect(!layer.enabled(in: session.fields))
    }
}
