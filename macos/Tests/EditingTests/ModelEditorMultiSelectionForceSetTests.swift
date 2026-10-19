import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class MultiSelectionLeveeProvider: ModelEditorProvider {
    static let tableID = "LeveeModPropertiesEditor/PropertySets"
    static let rows: Set<String> = ["property-a", "property-b"]
    static let detailScope = "TerrainSelection/property-a+property-b"

    private(set) var receivedCommand: LeveePropertyForceSetCommand?
    private(set) var receivedValue: String?
    private(set) var receivedRows: Set<String>?
    private(set) var editTerrainCallCount = 0
    private(set) var saveCount = 0
    var deferForceSet = false
    private var pendingForceSet: CheckedContinuation<EditorSnapshot, any Error>?
    private var pendingResponse: EditorSnapshot?

    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot {
        makeSnapshot(asset: asset, selectedRows: Self.rows)
    }

    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws {
        saveCount += 1
    }

    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot {
        guard case .selectTableRows(let table, let ids) = action, table == Self.tableID else {
            throw ProjectFileError.invalid("Unexpected multi-selection test action.")
        }
        return makeSnapshot(asset: asset, selectedRows: ids)
    }

    func editTerrain(_ asset: ProjectAsset, action: EditorAction,
                     edits: EditorEdits) async throws -> EditorSnapshot {
        editTerrainCallCount += 1
        guard case .forceSetLeveeProperty(let command, let value, let rowIDs, _) = action,
              rowIDs == Self.rows else {
            throw ProjectFileError.invalid("The exact Levee ForceSet request was not received.")
        }
        receivedCommand = command
        receivedValue = value
        receivedRows = rowIDs
        let response = makeSnapshot(asset: asset, selectedRows: rowIDs,
            modeValues: ["property-a": command == .mode ? value : "SimpleFill",
                         "property-b": command == .mode ? value : "SimpleCut"],
            modTypeValues: ["property-a": command == .modificationType ? value : "SetValue",
                            "property-b": command == .modificationType ? value : "TakeHigher"],
            isModeMixed: command != .mode, isModTypeMixed: command != .modificationType,
            sourceState: "draft-after-\(command.rawValue)-\(value)")
        guard deferForceSet else { return response }
        deferForceSet = false
        guard !Task.isCancelled else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            pendingResponse = response
            pendingForceSet = continuation
        }
    }

    func waitForForceSet() async -> Bool {
        for _ in 0..<100 {
            if pendingForceSet != nil { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return pendingForceSet != nil
    }

    func finishForceSet() {
        guard let continuation = pendingForceSet, let response = pendingResponse else { return }
        pendingForceSet = nil
        pendingResponse = nil
        continuation.resume(returning: response)
    }

    func cancelPendingForceSet() {
        guard let continuation = pendingForceSet else { return }
        pendingForceSet = nil
        pendingResponse = nil
        continuation.resume(throwing: CancellationError())
    }

    private func makeSnapshot(asset: ProjectAsset, selectedRows: Set<String>,
                              modeValues: [String: String] = ["property-a": "SimpleFill", "property-b": "SimpleCut"],
                              modTypeValues: [String: String] = ["property-a": "SetValue", "property-b": "TakeHigher"],
                              isModeMixed: Bool = true, isModTypeMixed: Bool = true,
                              sourceState: String? = nil) -> EditorSnapshot {
        let sorted = selectedRows.sorted()
        let scope = "TerrainSelection/" + sorted.joined(separator: "+")
        let modeField = scope + "/LeveeModPropertiesDetailEditor/Mode"
        let modTypeField = scope + "/LeveeModPropertiesDetailEditor/ModType"
        let sourceID = TerrainEditorContract.sourceField
        let details = selectedRows.reduce(into: [String: String]()) { result, id in
            result[id] = id == "property-a" ? "Primary" : "Secondary"
        }
        let mode = selectedRows.sorted().first.flatMap { modeValues[$0] } ?? ""
        let modType = selectedRows.sorted().first.flatMap { modTypeValues[$0] } ?? ""
        let properties = selectedRows.sorted().map { id in
            EditorRow(id: id, values: ["Name": details[id] ?? id,
                "Mode": modeValues[id] ?? "", "ModType": modTypeValues[id] ?? ""])
        }
        let input = EditorChoice(id: "levee-input", title: "Levee input")
        return EditorSnapshot(fields: [
            sourceID: input.id,
            modeField: mode,
            scope + "/LeveeModPropertiesDetailEditor/ModeHasMismatch": String(isModeMixed),
            modTypeField: modType,
            scope + "/LeveeModPropertiesDetailEditor/ModTypeHasMismatch": String(isModTypeMixed)
        ], rows: [Self.tableID: properties], samples: [:], canEdit: true, images: [:],
            choiceOptions: [modeField: [.init(id: "SimpleFill", title: "Simple Fill"), .init(id: "SimpleCut", title: "Simple Cut")],
                modTypeField: [.init(id: "SetValue", title: "Set Value"), .init(id: "TakeHigher", title: "Take Higher")]],
            sourceCollections: [sourceID: .init(items: [input], sourcePriorityReversed: false,
                canImport: false, canReorder: false, multipleImports: false,
                itemDetails: [input.id: .init(scope: "LeveeInput", schemaIDs: [],
                    terrainInfo: .init(type: "Levee", filename: nil, error: nil, validExtent: nil))])],
            tablePresentations: [Self.tableID: .init(columns: [], selection: .init(rowIDs: selectedRows,
                detail: .init(scope: scope, schemaIDs: ["LeveeModPropertiesDetailEditor"])))],
            sourceRevision: asset.name + "-revision", sourceState: sourceState ?? "source-\(asset.name)")
    }
}

@MainActor
private final class ArcForceSetModelProvider: ModelEditorProvider {
    static let tableID = "Arcs"
    static let editorRows: Set<String> = ["arc-row-7", "arc-row-11"]
    static let detailScope = "ArcSelection/arc-row-7+arc-row-11"

    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot {
        let schema = try #require(SourceEditorLibrary.shared.schema("ConceptualMeshArcEditor"))
        var fields = Dictionary(uniqueKeysWithValues: schema.fields.compactMap { field -> (String, String)? in
            switch field.id {
            case "ViewModel_ConstrainStretching": return (Self.detailScope + "/ConceptualMeshArcEditor/" + field.id, "Default")
            case "ViewModel_LaplaceBC": return (Self.detailScope + "/ConceptualMeshArcEditor/" + field.id, "ZeroFlux")
            case "ViewModel_BiasString": return (Self.detailScope + "/ConceptualMeshArcEditor/" + field.id, "")
            default: return nil
            }
        })
        // Mismatch flags are runtime values supplied by the selected-source
        // adapter; they are referenced by schema fields but are not schema
        // entries themselves.
        for mismatchID in ["ViewModel_ConstrainStretchingHasMismatch",
                           "ViewModel_LaplaceBCHasMismatch",
                           "ViewModel_BiasHasMismatch"] {
            fields[Self.detailScope + "/ConceptualMeshArcEditor/" + mismatchID] = "true"
        }
        return EditorSnapshot(fields: fields,
            rows: [Self.tableID: [
                .init(id: "arc-row-7", values: ["FID": "7", "ConstrainStretching": "Default", "LaplaceBC": "ZeroFlux", "Bias": "1.25"]),
                .init(id: "arc-row-11", values: ["FID": "11", "ConstrainStretching": "Constrained", "LaplaceBC": "Dirichlet", "Bias": "2.5"])
            ]], samples: [:], canEdit: true, images: [:],
            tablePresentations: [Self.tableID: .init(columns: [], selection: .init(rowIDs: Self.editorRows,
                detail: .init(scope: Self.detailScope, schemaIDs: ["ConceptualMeshArcEditor"])))],
            sourceRevision: "arc-geometry-r1", sourceState: "arc-model-state")
    }

    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws {}
    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot {
        throw ProjectFileError.invalid("Unexpected parent editor action.")
    }
}

@MainActor
private final class ArcForceSetTopologyProvider: GeometryTopologyProvider {
    private struct DraftState: Codable {
        let assetPath: String
        let revision: String
        var mutations: [GeometryTopologyMutation]
        var redoMutations: [GeometryTopologyMutation]
        let recentArcTags: [GeometryTopologyRecentTag]
        let recentRegionTags: [GeometryTopologyRecentTag]
    }

    private(set) var mutations: [GeometryTopologyMutation] = []
    var deferNextEdit = false
    private var pendingEdit: CheckedContinuation<GeometryTopologySnapshot, any Error>?
    private var pendingResponse: GeometryTopologySnapshot?

    func modelRequest(for asset: ProjectAsset) -> GeometryTopologyModelRequest {
        .init(assetPath: asset.url.path, kind: "Geometry", projectPath: nil, projectXml: nil)
    }

    func load(_ model: GeometryTopologyModelRequest, expectedRevision: String?) async throws -> GeometryTopologySnapshot {
        Self.snapshot(assetPath: model.assetPath, revision: expectedRevision ?? "arc-geometry-r1", rows: Self.initialRows)
    }

    func edit(_ model: GeometryTopologyModelRequest, revision: String, draftState: String,
              mutation: GeometryTopologyMutation) async throws -> GeometryTopologySnapshot {
        mutations.append(mutation)
        let priorDraft = try Self.decodeDraftState(draftState)
        guard priorDraft.assetPath == model.assetPath, priorDraft.revision == revision else {
            throw ProjectFileError.invalid("The Arc topology draft owner changed.")
        }
        var rows = Self.initialRows
        for priorMutation in priorDraft.mutations {
            try Self.apply(priorMutation, to: &rows)
        }
        try Self.apply(mutation, to: &rows)
        let response = Self.snapshot(assetPath: model.assetPath, revision: revision, rows: rows,
            isDirty: true, canUndo: true, mutations: priorDraft.mutations + [mutation])
        guard deferNextEdit else { return response }
        deferNextEdit = false
        guard !Task.isCancelled else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            pendingResponse = response
            pendingEdit = continuation
        }
    }

    func save(_ model: GeometryTopologyModelRequest, revision: String,
              draftState: String) async throws -> GeometryTopologySnapshot {
        Self.snapshot(assetPath: model.assetPath, revision: revision, rows: Self.initialRows)
    }

    func waitForEdit() async -> Bool {
        for _ in 0..<100 {
            if pendingEdit != nil { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return pendingEdit != nil
    }

    func finishEdit() {
        guard let continuation = pendingEdit, let response = pendingResponse else { return }
        pendingEdit = nil
        pendingResponse = nil
        continuation.resume(returning: response)
    }

    func cancelPendingEdit() {
        guard let continuation = pendingEdit else { return }
        pendingEdit = nil
        pendingResponse = nil
        continuation.resume(throwing: CancellationError())
    }

    private static let initialRows = [
        GeometryTopologyFeatureRow(id: "arc:7", fid: 7, values: ["FID": "7", "ConstrainStretching": "Default", "LaplaceBC": "ZeroFlux", "Bias": "1.25"]),
        GeometryTopologyFeatureRow(id: "arc:11", fid: 11, values: ["FID": "11", "ConstrainStretching": "Constrained", "LaplaceBC": "Dirichlet", "Bias": "2.5"])
    ]

    private static func replacingValue(in row: GeometryTopologyFeatureRow, field: String,
                                       value: String) -> GeometryTopologyFeatureRow {
        var values = row.values
        values[field] = value
        return GeometryTopologyFeatureRow(id: row.id, fid: row.fid, values: values,
            x: row.x, y: row.y, startNodeID: row.startNodeID, endNodeID: row.endNodeID)
    }

    private static func snapshot(assetPath: String = "/fixture/Geometry.hdf", revision: String,
                                 rows: [GeometryTopologyFeatureRow],
                                 isDirty: Bool = false, canUndo: Bool = false,
                                 mutations: [GeometryTopologyMutation] = []) -> GeometryTopologySnapshot {
        let draft = topologyDraft(assetPath: assetPath, revision: revision, mutations: mutations)
        return GeometryTopologySnapshot(revision: revision, draftState: draft, canEdit: true, isDirty: isDirty,
            arcs: .init(featureKind: "arc", columns: [], editableFields: [], rows: rows),
            regions: .init(featureKind: "region", columns: [], editableFields: [], rows: []),
            nodes: .init(featureKind: "node", columns: [], editableFields: [], rows: []),
            arcTags: [], regionTags: [], recentArcTags: [], recentRegionTags: [],
            canUndo: canUndo, canRedo: false)
    }

    private static func decodeDraftState(_ value: String) throws -> DraftState {
        try JSONDecoder().decode(DraftState.self, from: Data(value.utf8))
    }

    private static func apply(_ mutation: GeometryTopologyMutation,
                              to rows: inout [GeometryTopologyFeatureRow]) throws {
        guard mutation.featureKind == "arc", !mutation.featureIDs.isEmpty,
              Set(mutation.featureIDs).count == mutation.featureIDs.count else {
            throw ProjectFileError.invalid("The Arc topology mutation has an invalid selection.")
        }
        let targetFIDs = Set(mutation.featureIDs)
        guard targetFIDs.isSubset(of: Set(rows.map(\.fid))) else {
            throw ProjectFileError.invalid("The Arc topology mutation references a missing row.")
        }
        switch mutation.operation {
        case "forceSetArcChoice":
            guard let field = mutation.fieldID, let value = mutation.value else {
                throw ProjectFileError.invalid("Missing Arc choice.")
            }
            for index in rows.indices where targetFIDs.contains(rows[index].fid) {
                rows[index] = Self.replacingValue(in: rows[index], field: field, value: value)
            }
        case "forceResetArcBias":
            for index in rows.indices where targetFIDs.contains(rows[index].fid) {
                rows[index] = Self.replacingValue(in: rows[index], field: "Bias", value: "NaN")
            }
        default:
            throw ProjectFileError.invalid("Unexpected topology mutation.")
        }
    }

    private static func topologyDraft(assetPath: String, revision: String,
                                      mutations: [GeometryTopologyMutation]) -> String {
        let draft = DraftState(assetPath: assetPath, revision: revision,
            mutations: mutations, redoMutations: [], recentArcTags: [], recentRegionTags: [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(data: try! encoder.encode(draft), encoding: .utf8)!
    }
}

@Suite(.serialized)
struct ModelEditorMultiSelectionForceSetTests {
    @Test @MainActor
    func mixedLeveeChoiceAppliesToEveryExactSelectedPropertyEvenWhenFirstValueIsChosen() async throws {
        let provider = MultiSelectionLeveeProvider()
        let editor = ModelEditorSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/levee.hdf"), section: .terrains)
        await editor.load(asset, kind: .terrain)

        let schema = try #require(SourceEditorLibrary.shared.schema("LeveeModPropertiesDetailEditor"))
        let field = try #require(schema.fields.first { $0.id == "Mode" }?.inScope(MultiSelectionLeveeProvider.detailScope))
        #expect(field.hasMixedDraft(in: editor))
        #expect(editor.fields[field.storageID] == "SimpleFill")
        #expect(editor.captureLeveeForceSetIdentity(field: field, value: "SimpleFill") != nil)

        #expect(await editor.forceSetLeveeProperty(field, value: "SimpleFill"))
        #expect(provider.receivedCommand == .mode)
        #expect(provider.receivedValue == "SimpleFill")
        #expect(provider.receivedRows == MultiSelectionLeveeProvider.rows)
        #expect(editor.rows[MultiSelectionLeveeProvider.tableID]?.allSatisfy { $0.values["Mode"] == "SimpleFill" } == true)
        #expect(editor.fields[field.scoped("ModeHasMismatch")] == "false")
        #expect(editor.modified)
        #expect(provider.saveCount == 0)

        let modType = try #require(schema.fields.first { $0.id == "ModType" }?.inScope(MultiSelectionLeveeProvider.detailScope))
        #expect(modType.hasMixedDraft(in: editor))
        #expect(editor.fields[modType.storageID] == "SetValue")
        #expect(await editor.forceSetLeveeProperty(modType, value: "SetValue"))
        #expect(provider.receivedCommand == .modificationType)
        #expect(provider.receivedValue == "SetValue")
        #expect(provider.receivedRows == MultiSelectionLeveeProvider.rows)
        #expect(editor.rows[MultiSelectionLeveeProvider.tableID]?.allSatisfy { $0.values["ModType"] == "SetValue" } == true)
        #expect(editor.fields[modType.scoped("ModTypeHasMismatch")] == "false")
        #expect(provider.saveCount == 0)
    }

    @Test @MainActor
    func leveeForceSetIdentityExpiresWhenSelectedPropertySetChanges() async throws {
        let provider = MultiSelectionLeveeProvider()
        let editor = ModelEditorSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/levee-selection.hdf"), section: .terrains)
        await editor.load(asset, kind: .terrain)
        let schema = try #require(SourceEditorLibrary.shared.schema("LeveeModPropertiesDetailEditor"))
        let field = try #require(schema.fields.first { $0.id == "Mode" }?.inScope(MultiSelectionLeveeProvider.detailScope))
        let identity = try #require(editor.captureLeveeForceSetIdentity(field: field, value: "SimpleFill"))
        #expect(editor.isCurrentLeveeForceSetIdentity(identity))

        #expect(await editor.perform(.selectTableRows(table: MultiSelectionLeveeProvider.tableID, ids: ["property-a"])))
        #expect(!editor.isCurrentLeveeForceSetIdentity(identity))
        #expect(editor.tablePresentations[MultiSelectionLeveeProvider.tableID]?.selection?.rowIDs == ["property-a"])
    }

    @Test @MainActor
    func leveeClickCaptureThenSelectionChangeBeforeDispatchIsRejectedWithoutForceSetCall() async throws {
        let provider = MultiSelectionLeveeProvider()
        let editor = ModelEditorSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/levee-capture-before-dispatch.hdf"), section: .terrains)
        await editor.load(asset, kind: .terrain)

        let schema = try #require(SourceEditorLibrary.shared.schema("LeveeModPropertiesDetailEditor"))
        let field = try #require(schema.fields.first { $0.id == "Mode" }?.inScope(MultiSelectionLeveeProvider.detailScope))
        let identity = try #require(editor.captureLeveeForceSetIdentity(field: field, value: "SimpleCut"))

        // Models selection changing after the click captured its immutable
        // owner but before the queued UI Task starts.
        #expect(await editor.perform(.selectTableRows(table: MultiSelectionLeveeProvider.tableID,
            ids: ["property-a"])))
        #expect(!editor.isCurrentLeveeForceSetIdentity(identity))
        #expect(!(await editor.forceSetLeveeProperty(identity)))
        #expect(provider.editTerrainCallCount == 0)
        #expect(provider.receivedCommand == nil)
    }

    @Test @MainActor
    func lateLeveeForceSetReplyCannotReplaceANewlyLoadedModel() async throws {
        let provider = MultiSelectionLeveeProvider()
        let editor = ModelEditorSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/levee-late.hdf"), section: .terrains)
        await editor.load(asset, kind: .terrain)
        let schema = try #require(SourceEditorLibrary.shared.schema("LeveeModPropertiesDetailEditor"))
        let field = try #require(schema.fields.first { $0.id == "Mode" }?.inScope(MultiSelectionLeveeProvider.detailScope))
        provider.deferForceSet = true

        let operation = Task { @MainActor in await editor.forceSetLeveeProperty(field, value: "SimpleFill") }
        guard await provider.waitForForceSet() else {
            operation.cancel()
            provider.cancelPendingForceSet()
            #expect(Bool(false), "Timed out waiting for the Levee ForceSet request to reach its provider.")
            _ = await operation.value
            return
        }
        let nextAsset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/next-levee.hdf"), section: .terrains)
        await editor.load(nextAsset, kind: .terrain)
        provider.finishForceSet()

        #expect(!(await operation.value))
        #expect(editor.modelAssetID == nextAsset.id)
        #expect(editor.sourceFileRevision == nextAsset.name + "-revision")
        #expect(editor.fields[field.storageID] == "SimpleFill")
        #expect(editor.fields[field.scoped("ModeHasMismatch")] == "true")
    }

    @Test @MainActor
    func arcMixedForceSetUsesExactChildRowsAndBiasClearUsesNaNCommand() async throws {
        let modelProvider = ArcForceSetModelProvider()
        let topologyProvider = ArcForceSetTopologyProvider()
        let editor = ModelEditorSession(provider: modelProvider, topologyProvider: topologyProvider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/arcs.hdf"), section: .geometries)
        await editor.load(asset, kind: .geometry)
        await editor.ensureGeometryTopologyLoaded()

        let schema = try #require(SourceEditorLibrary.shared.schema("ConceptualMeshArcEditor"))
        let stretching = try #require(
            schema.fields.first { $0.id == "ViewModel_ConstrainStretching" }?.inScope(ArcForceSetModelProvider.detailScope))
        #expect(stretching.forceSetCommand == GeometryArcForceSetCommand.constrainStretching.rawValue)
        #expect(stretching.hasMixedDraft(in: editor))
        #expect(await editor.forceSetGeometryArcChoice(stretching, value: "Default"))
        #expect(topologyProvider.mutations.last?.operation == "forceSetArcChoice")
        #expect(topologyProvider.mutations.last?.featureKind == "arc")
        #expect(topologyProvider.mutations.last?.featureIDs == [7, 11])
        #expect(topologyProvider.mutations.last?.fieldID == "ConstrainStretching")
        #expect(topologyProvider.mutations.last?.value == "Default")
        #expect(editor.fields[stretching.storageID] == "Default")
        #expect(editor.fields[stretching.scoped("ViewModel_ConstrainStretchingHasMismatch")] == "false")
        #expect(editor.rows[ArcForceSetModelProvider.tableID]?.allSatisfy { $0.values["ConstrainStretching"] == "Default" } == true)

        let laplace = try #require(
            schema.fields.first { $0.id == "ViewModel_LaplaceBC" }?.inScope(ArcForceSetModelProvider.detailScope))
        #expect(await editor.forceSetGeometryArcChoice(laplace, value: "ZeroFlux"))
        #expect(topologyProvider.mutations.last?.operation == "forceSetArcChoice")
        #expect(topologyProvider.mutations.last?.featureIDs == [7, 11])
        #expect(topologyProvider.mutations.last?.fieldID == "LaplaceBC")
        #expect(topologyProvider.mutations.last?.value == "ZeroFlux")
        #expect(editor.fields[laplace.storageID] == "ZeroFlux")
        #expect(editor.fields[laplace.scoped("ViewModel_LaplaceBCHasMismatch")] == "false")
        #expect(editor.rows[ArcForceSetModelProvider.tableID]?.allSatisfy { $0.values["LaplaceBC"] == "ZeroFlux" } == true)

        let bias = try #require(
            schema.fields.first { $0.id == "ViewModel_BiasString" }?.inScope(ArcForceSetModelProvider.detailScope))
        #expect(bias.clearCommand == GeometryArcClearCommand.resetBias.rawValue)
        #expect(bias.showClearButton == true)
        #expect(await editor.resetGeometryArcBias(bias))
        #expect(topologyProvider.mutations.last?.operation == "forceResetArcBias")
        #expect(topologyProvider.mutations.last?.fieldID == "Bias")
        #expect(topologyProvider.mutations.last?.value == nil)
        #expect(editor.fields[bias.storageID] == "")
        #expect(editor.fields[bias.scoped("ViewModel_BiasHasMismatch")] == "false")
        #expect(editor.rows[ArcForceSetModelProvider.tableID]?.allSatisfy { $0.values["Bias"] == "NaN" } == true)
    }

    @Test @MainActor
    func arcChoiceAndBiasClickCapturesRejectParentEditBeforeDispatchWithoutChildMutation() async throws {
        let modelProvider = ArcForceSetModelProvider()
        let topologyProvider = ArcForceSetTopologyProvider()
        let editor = ModelEditorSession(provider: modelProvider, topologyProvider: topologyProvider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/arcs-capture-before-dispatch.hdf"), section: .geometries)
        await editor.load(asset, kind: .geometry)
        await editor.ensureGeometryTopologyLoaded()

        let schema = try #require(SourceEditorLibrary.shared.schema("ConceptualMeshArcEditor"))
        let choice = try #require(
            schema.fields.first { $0.id == "ViewModel_ConstrainStretching" }?.inScope(ArcForceSetModelProvider.detailScope))
        let bias = try #require(
            schema.fields.first { $0.id == "ViewModel_BiasString" }?.inScope(ArcForceSetModelProvider.detailScope))
        let choiceIdentity = try #require(editor.captureGeometryArcForceSetIdentity(field: choice, value: "Default"))
        let biasIdentity = try #require(editor.captureGeometryArcBiasResetIdentity(field: bias))

        // A parent edit after the click invalidates both captured actions.
        // Neither queued operation may select or mutate the topology child.
        editor.set(choice.storageID, "Constrained")
        #expect(!editor.isCurrentGeometryArcForceSetIdentity(choiceIdentity))
        #expect(!editor.isCurrentGeometryArcBiasResetIdentity(biasIdentity))
        #expect(!(await editor.forceSetGeometryArcChoice(choiceIdentity)))
        #expect(!(await editor.resetGeometryArcBias(biasIdentity)))
        #expect(topologyProvider.mutations.isEmpty)
        #expect(editor.geometryTopology?.snapshot?.isDirty == false)
    }

    @Test @MainActor
    func lateArcForceSetReplyAfterChildSelectionChangesDoesNotInstallDraft() async throws {
        let modelProvider = ArcForceSetModelProvider()
        let topologyProvider = ArcForceSetTopologyProvider()
        topologyProvider.deferNextEdit = true
        let editor = ModelEditorSession(provider: modelProvider, topologyProvider: topologyProvider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/arcs-stale.hdf"), section: .geometries)
        await editor.load(asset, kind: .geometry)
        await editor.ensureGeometryTopologyLoaded()

        let schema = try #require(SourceEditorLibrary.shared.schema("ConceptualMeshArcEditor"))
        let field = try #require(
            schema.fields.first { $0.id == "ViewModel_ConstrainStretching" }?.inScope(ArcForceSetModelProvider.detailScope))
        let topology = try #require(editor.geometryTopology)
        let operation = Task { @MainActor in await editor.forceSetGeometryArcChoice(field, value: "Default") }
        guard await topologyProvider.waitForEdit() else {
            operation.cancel()
            topologyProvider.cancelPendingEdit()
            #expect(Bool(false), "Timed out waiting for the Arc ForceSet request to reach its provider.")
            _ = await operation.value
            return
        }
        topology.select(["arc:999"], featureKind: "arc")
        topologyProvider.finishEdit()

        #expect(!(await operation.value))
        #expect(topology.snapshot?.arcs.rows.first { $0.fid == 11 }?.values["ConstrainStretching"] == "Constrained")
        #expect(editor.fields[field.scoped("ViewModel_ConstrainStretchingHasMismatch")] == "true")
        #expect(editor.rows[ArcForceSetModelProvider.tableID]?.first { $0.values["FID"] == "11" }?.values["ConstrainStretching"] == "Constrained")
    }
}
