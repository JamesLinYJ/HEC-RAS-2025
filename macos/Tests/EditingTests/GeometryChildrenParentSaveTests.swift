import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class GeometryChildrenParentProvider: ModelEditorProvider {
    static let descriptionField = "GeometryChildrenParentSaveTests/Description"
    static let imageField = "GeometryChildrenParentSaveTests/Images"

    private(set) var saveRequests: [(asset: ProjectAsset, edits: EditorEdits)] = []
    private var saveContinuations: [Int: CheckedContinuation<EditorSaveResult, any Error>] = [:]

    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot {
        EditorSnapshot(
            fields: [Self.descriptionField: "source: \(asset.name)"], rows: [:], samples: [:], canEdit: true,
            images: [Self.imageField: [.init(id: "source-image", name: "source.png", data: Data([1, 2]))]],
            sourceRevision: "parent-source:\(asset.name)")
    }

    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws {}

    func saveModel(_ asset: ProjectAsset, changes: EditorEdits) async throws -> EditorSaveResult {
        let request = saveRequests.count + 1
        saveRequests.append((asset, changes))
        return try await withCheckedThrowingContinuation { saveContinuations[request] = $0 }
    }

    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot {
        try await load(asset, kind: .geometry)
    }

    func finishSave(_ request: Int, revision: String) {
        saveContinuations.removeValue(forKey: request)?.resume(returning: EditorSaveResult(sourceRevision: revision))
    }

    func failSave(_ request: Int, error: any Error) {
        saveContinuations.removeValue(forKey: request)?.resume(throwing: error)
    }
}

private struct PendingTopologyMutation {
    let model: GeometryTopologyModelRequest
    let revision: String
    let mutation: GeometryTopologyMutation
}

@MainActor
private final class GeometryChildrenTopologyProvider: GeometryTopologyProvider {
    private(set) var editRequests: [PendingTopologyMutation] = []
    var suspendNextEdit = false
    private var continuations: [Int: CheckedContinuation<GeometryTopologySnapshot, any Error>] = [:]

    func modelRequest(for asset: ProjectAsset) -> GeometryTopologyModelRequest {
        .init(assetPath: asset.url.path, kind: "Geometry", projectPath: nil, projectXml: nil)
    }

    func load(_ model: GeometryTopologyModelRequest, expectedRevision: String?) async throws -> GeometryTopologySnapshot {
        let revision = expectedRevision ?? "topology-source:\(URL(fileURLWithPath: model.assetPath).lastPathComponent)"
        return Self.snapshot(revision: revision, draftState: "topology-source-draft:\(revision)", isDirty: false, rowName: "source")
    }

    func edit(_ model: GeometryTopologyModelRequest, revision: String, draftState: String,
              mutation: GeometryTopologyMutation) async throws -> GeometryTopologySnapshot {
        let pending = PendingTopologyMutation(model: model, revision: revision, mutation: mutation)
        editRequests.append(pending)
        let index = editRequests.count
        if suspendNextEdit {
            suspendNextEdit = false
            return try await withCheckedThrowingContinuation { continuations[index] = $0 }
        }
        return Self.editedSnapshot(pending)
    }

    func save(_ model: GeometryTopologyModelRequest, revision: String,
              draftState: String) async throws -> GeometryTopologySnapshot {
        Self.snapshot(revision: revision, draftState: "topology-source-draft:\(revision)", isDirty: false, rowName: "source")
    }

    func finishEdit(_ request: Int) {
        guard editRequests.indices.contains(request - 1) else { return }
        continuations.removeValue(forKey: request)?.resume(returning: Self.editedSnapshot(editRequests[request - 1]))
    }

    private static func editedSnapshot(_ pending: PendingTopologyMutation) -> GeometryTopologySnapshot {
        snapshot(revision: pending.revision, draftState: "topology-draft:\(pending.mutation.value ?? "edit")",
            isDirty: true, rowName: pending.mutation.value ?? "edited")
    }

    private static func snapshot(revision: String, draftState: String, isDirty: Bool,
                                 rowName: String) -> GeometryTopologySnapshot {
        let field = GeometryTopologyField(id: "Name", title: "Name", sourceType: "string", choices: [], readOnly: false)
        let arcs = GeometryTopologyFeatureTable(featureKind: "arc", columns: [
            GeometryTopologyColumn(id: "Name", title: "Name", sourceType: "string", readOnly: false, isTag: false)
        ], editableFields: [field], rows: [
            GeometryTopologyFeatureRow(id: "arc-7", fid: 7, values: ["Name": rowName])
        ])
        return GeometryTopologySnapshot(revision: revision, draftState: draftState, canEdit: true, isDirty: isDirty,
            arcs: arcs,
            regions: GeometryTopologyFeatureTable(featureKind: "region", columns: [], editableFields: [], rows: []),
            nodes: GeometryTopologyFeatureTable(featureKind: "node", columns: [], editableFields: [], rows: []),
            arcTags: [], regionTags: [], recentArcTags: [], recentRegionTags: [])
    }
}

private struct PendingMeshMutation {
    let model: GeometryMeshModelRequest
    let revision: String
    let topologyDraftState: String?
    let mutation: GeometryMeshMutation
}

@MainActor
private final class GeometryChildrenMeshProvider: GeometryMeshProvider {
    var topologyDraftState: String?
    private(set) var editRequests: [PendingMeshMutation] = []
    var suspendNextEdit = false
    private var continuations: [Int: CheckedContinuation<GeometryMeshSnapshot, any Error>] = [:]

    func modelRequest(for asset: ProjectAsset) -> GeometryMeshModelRequest {
        .init(assetPath: asset.url.path, kind: "Geometry", projectPath: nil, projectXml: nil)
    }

    func currentTopologyDraftState() -> String? { topologyDraftState }

    func load(_ model: GeometryMeshModelRequest, expectedRevision: String?, draftState: String?,
              topologyDraftState: String?, selectedRegionIDs: [Int]) async throws -> GeometryMeshSnapshot {
        let revision = expectedRevision ?? "mesh-source:\(URL(fileURLWithPath: model.assetPath).lastPathComponent)"
        return Self.snapshot(revision: revision, draftState: "mesh-source-draft:\(revision)",
            topologyDraftState: topologyDraftState, isDirty: false)
    }

    func edit(_ model: GeometryMeshModelRequest, revision: String, draftState: String,
              topologyDraftState: String?, mutation: GeometryMeshMutation,
              selectedRegionIDs: [Int]) async throws -> GeometryMeshSnapshot {
        let pending = PendingMeshMutation(model: model, revision: revision,
            topologyDraftState: topologyDraftState, mutation: mutation)
        editRequests.append(pending)
        let index = editRequests.count
        if suspendNextEdit {
            suspendNextEdit = false
            return try await withCheckedThrowingContinuation { continuations[index] = $0 }
        }
        return Self.editedSnapshot(pending)
    }

    func scanDegreeErrors(_ model: GeometryMeshModelRequest, revision: String, draftState: String,
                          topologyDraftState: String?, maxFacesPerNode: Int) async throws -> GeometryMeshDegreeScan {
        GeometryMeshDegreeScan(maxFacesPerNode: maxFacesPerNode, issues: [])
    }

    func finishEdit(_ request: Int) {
        guard editRequests.indices.contains(request - 1) else { return }
        continuations.removeValue(forKey: request)?.resume(returning: Self.editedSnapshot(editRequests[request - 1]))
    }

    private static func editedSnapshot(_ pending: PendingMeshMutation) -> GeometryMeshSnapshot {
        snapshot(revision: pending.revision,
            draftState: "mesh-draft:\(pending.mutation.operation):\(pending.mutation.value ?? "edit")",
            topologyDraftState: pending.topologyDraftState, isDirty: true)
    }

    private static func snapshot(revision: String, draftState: String,
                                 topologyDraftState: String?, isDirty: Bool) -> GeometryMeshSnapshot {
        GeometryMeshSnapshot(revision: revision, draftState: draftState,
            topologyFingerprint: topologyDraftState ?? "", canEdit: true, isDirty: isDirty,
            flowAreas: [],
            regions: GeometryTopologyFeatureTable(featureKind: "region", columns: [], editableFields: [], rows: []),
            selectedRegionIDs: [], patchSizing: nil, generationReport: nil, prepareSummary: nil)
    }
}

private struct PendingCulvertMutation {
    let model: GeometryCulvertModelRequest
    let revision: String
    let mutation: GeometryCulvertMutation
}

@MainActor
private final class GeometryChildrenCulvertProvider: GeometryCulvertProvider {
    private(set) var editRequests: [PendingCulvertMutation] = []
    var suspendNextEdit = false
    private var continuations: [Int: CheckedContinuation<GeometryCulvertSnapshot, any Error>] = [:]

    func modelRequest(for asset: ProjectAsset) -> GeometryCulvertModelRequest {
        .init(assetPath: asset.url.path, kind: "Geometry", projectPath: nil, projectXml: nil)
    }

    func load(_ model: GeometryCulvertModelRequest, expectedRevision: String?, draftState: String?,
              selectedBarrelIDs: [String]) async throws -> GeometryCulvertSnapshot {
        let revision = expectedRevision ?? "culvert-source:\(URL(fileURLWithPath: model.assetPath).lastPathComponent)"
        return Self.snapshot(revision: revision, draftState: "culvert-source-draft:\(revision)", isDirty: false)
    }

    func edit(_ model: GeometryCulvertModelRequest, revision: String, draftState: String,
              mutation: GeometryCulvertMutation, selectedBarrelIDs: [String]) async throws -> GeometryCulvertSnapshot {
        let pending = PendingCulvertMutation(model: model, revision: revision, mutation: mutation)
        editRequests.append(pending)
        let index = editRequests.count
        if suspendNextEdit {
            suspendNextEdit = false
            return try await withCheckedThrowingContinuation { continuations[index] = $0 }
        }
        return Self.editedSnapshot(pending)
    }

    func finishEdit(_ request: Int) {
        guard editRequests.indices.contains(request - 1) else { return }
        continuations.removeValue(forKey: request)?.resume(returning: Self.editedSnapshot(editRequests[request - 1]))
    }

    private static func editedSnapshot(_ pending: PendingCulvertMutation) -> GeometryCulvertSnapshot {
        snapshot(revision: pending.revision,
            draftState: "culvert-draft:\(pending.mutation.operation):\(pending.mutation.featureKind)", isDirty: true)
    }

    private static func snapshot(revision: String, draftState: String, isDirty: Bool) -> GeometryCulvertSnapshot {
        func table(_ featureKind: String) -> GeometryCulvertFeatureTable {
            GeometryCulvertFeatureTable(featureKind: featureKind, columns: [], editableFields: [], rows: [])
        }
        return GeometryCulvertSnapshot(revision: revision, draftState: draftState, canEdit: true, isDirty: isDirty,
            barrels: table("barrel"), barrelProperties: table("barrelProperties"),
            openingProperties: table("openingProperties"), associatedTerrainName: nil, profiles: [])
    }
}

@MainActor
private final class GeometryChildrenHarness {
    let modelProvider: GeometryChildrenParentProvider
    let topologyProvider: GeometryChildrenTopologyProvider
    let meshProvider: GeometryChildrenMeshProvider
    let culvertProvider: GeometryChildrenCulvertProvider
    let session: ModelEditorSession
    let initialAsset: ProjectAsset

    init(assetName: String = "Geometry Parent.hdf") {
        let modelProvider = GeometryChildrenParentProvider()
        let topologyProvider = GeometryChildrenTopologyProvider()
        let meshProvider = GeometryChildrenMeshProvider()
        let culvertProvider = GeometryChildrenCulvertProvider()
        self.modelProvider = modelProvider
        self.topologyProvider = topologyProvider
        self.meshProvider = meshProvider
        self.culvertProvider = culvertProvider
        initialAsset = Self.asset(assetName)
        session = ModelEditorSession(provider: modelProvider, topologyProvider: topologyProvider,
            meshProvider: meshProvider, culvertProvider: culvertProvider)
    }

    func load(_ asset: ProjectAsset? = nil) async {
        let target = asset ?? initialAsset
        await session.load(target, kind: .geometry)
        meshProvider.topologyDraftState = session.geometryTopology?.topologyStateForParentSave
        await session.ensureGeometryTopologyLoaded()
        await session.ensureGeometryMeshLoaded()
        await session.ensureGeometryCulvertLoaded()
    }

    func editAllChildren(suffix: String = "A") async {
        await session.geometryTopology?.setField(featureKind: "arc", fid: 7, fieldID: "Name", value: "arc-\(suffix)")
        meshProvider.topologyDraftState = session.geometryTopology?.topologyStateForParentSave
        await session.ensureGeometryMeshLoaded()
        await session.geometryMesh?.setPatchField(featureIDs: [7], fieldID: "Name", value: "patch-\(suffix)")
        await session.geometryCulvert?.addPropertySet(featureKind: "barrelProperties")
    }

    static func asset(_ name: String) -> ProjectAsset {
        ProjectAsset(url: URL(fileURLWithPath: "/task-fixture/\(name)"), section: .geometries)
    }
}

@Suite(.serialized)
struct GeometryChildrenParentSaveTests {
    @Test @MainActor
    func unfinishedCulvertSketchCannotBeLostBySaveDiscardCloseOrAssetReplacement() async throws {
        let harness = GeometryChildrenHarness()
        await harness.load()
        let child = try #require(harness.session.geometryCulvert)
        let store = WorkspaceStore(modelProvider: harness.modelProvider)
        store.registerEditor(harness.session, primaryKind: .geometry)
        store.openEditors = [.geometry]
        child.setSketchActive(true)
        #expect(harness.session.modified && harness.session.isBusy)
        #expect(!child.canBeginParentSave)
        #expect(!(await harness.session.saveLoadedModel()))
        #expect(harness.modelProvider.saveRequests.isEmpty)
        harness.session.discardEdits()
        store.requestCloseTab(.editor(.geometry))
        #expect(store.openEditors == [.geometry] && !store.showCloseTabConfirmation)
        await harness.session.load(GeometryChildrenHarness.asset("Other geometry.hdf"), kind: .geometry)
        #expect(harness.session.modelAssetID == harness.initialAsset.id)
        #expect(child.hasActiveSketch && harness.session.isBusy)
        harness.session.set(GeometryChildrenParentProvider.descriptionField, "Keep ordinary draft")
        child.setSketchActive(false)
        #expect(!harness.session.isBusy && harness.session.modified)
        #expect(harness.session.fields[GeometryChildrenParentProvider.descriptionField] == "Keep ordinary draft")
    }

    @Test @MainActor
    func discardingOneChildRetainsOtherChildAndOrdinaryDrafts() async throws {
        let harness = GeometryChildrenHarness()
        await harness.load()
        harness.session.set(GeometryChildrenParentProvider.descriptionField, "edited description")
        harness.session.addImage(GeometryChildrenParentProvider.imageField,
            image: .init(id: "draft-image", name: "draft.png", data: Data([3, 4])))
        await harness.editAllChildren()
        #expect(harness.session.geometryTopology?.isDirty == true)
        #expect(harness.session.geometryMesh?.isDirty == true)
        #expect(harness.session.geometryCulvert?.isDirty == true)

        await harness.session.geometryCulvert?.discardDraft()

        #expect(harness.session.geometryCulvert?.isDirty == false)
        #expect(harness.session.geometryTopology?.isDirty == true)
        #expect(harness.session.geometryMesh?.isDirty == true)
        #expect(harness.session.fields[GeometryChildrenParentProvider.descriptionField] == "edited description")
        #expect(harness.session.images[GeometryChildrenParentProvider.imageField]?.map(\.id) == ["source-image", "draft-image"])
        #expect(harness.session.modified)
    }

    @Test @MainActor
    func oneFailedParentSaveCapturesAllThreeChildrenAndKeepsEveryDraft() async throws {
        let harness = GeometryChildrenHarness()
        await harness.load()
        harness.session.set(GeometryChildrenParentProvider.descriptionField, "edited description")
        harness.session.addImage(GeometryChildrenParentProvider.imageField,
            image: .init(id: "draft-image", name: "draft.png", data: Data([5, 6])))
        await harness.editAllChildren()
        let topologyState = try #require(harness.session.geometryTopology?.topologyStateForParentSave)
        let meshState = try #require(harness.session.geometryMesh?.geometryMeshStateForParentSave)
        let culvertState = try #require(harness.session.geometryCulvert?.geometryCulvertStateForParentSave)

        let saving = Task { await harness.session.save(harness.initialAsset) }
        #expect(await waitUntil { harness.modelProvider.saveRequests.count == 1 })
        let request = try #require(harness.modelProvider.saveRequests.first)
        #expect(request.asset == harness.initialAsset)
        #expect(request.edits.fields[GeometryChildrenParentProvider.descriptionField] == "edited description")
        #expect(request.edits.images[GeometryChildrenParentProvider.imageField]?.map(\.id) == ["source-image", "draft-image"])
        #expect(request.edits.geometryTopologyState == topologyState)
        #expect(request.edits.geometryMeshState == meshState)
        #expect(request.edits.geometryCulvertState == culvertState)
        #expect(harness.session.geometryTopology?.parentSaveInProgress == true)
        #expect(harness.session.geometryMesh?.parentSaveInProgress == true)
        #expect(harness.session.geometryCulvert?.parentSaveInProgress == true)

        harness.modelProvider.failSave(1, error: CocoaError(.fileWriteNoPermission))
        #expect(!(await saving.value))
        #expect(harness.session.modified)
        #expect(harness.session.fields[GeometryChildrenParentProvider.descriptionField] == "edited description")
        #expect(harness.session.images[GeometryChildrenParentProvider.imageField]?.map(\.id) == ["source-image", "draft-image"])
        #expect(harness.session.geometryTopology?.topologyStateForParentSave == topologyState)
        #expect(harness.session.geometryMesh?.geometryMeshStateForParentSave == meshState)
        #expect(harness.session.geometryCulvert?.geometryCulvertStateForParentSave == culvertState)
        #expect(harness.session.geometryTopology?.isDirty == true)
        #expect(harness.session.geometryMesh?.isDirty == true)
        #expect(harness.session.geometryCulvert?.isDirty == true)
        #expect(harness.session.geometryTopology?.parentSaveInProgress == false)
        #expect(harness.session.geometryMesh?.parentSaveInProgress == false)
        #expect(harness.session.geometryCulvert?.parentSaveInProgress == false)
    }

    @Test @MainActor
    func everyBusyGeometryChildBlocksSaveDiscardAndCloseUntilItsOperationCompletes() async throws {
        enum Child { case topology, mesh, culvert }
        let suiteName = "GeometryChildrenParentSaveTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for child in [Child.topology, .mesh, .culvert] {
            let harness = GeometryChildrenHarness(assetName: "Geometry Busy.hdf")
            await harness.load()
            let store = WorkspaceStore(modelProvider: harness.modelProvider,
                recentHistoryStore: RecentProjectHistoryStore(defaults: defaults))
            store.registerEditor(harness.session, primaryKind: .geometry)
            store.openEditors = [.geometry]
            harness.session.set(GeometryChildrenParentProvider.descriptionField, "keep this edit")

            let editing: Task<Void, Never>
            let isChildEditing: @MainActor () -> Bool
            switch child {
            case .topology:
                harness.topologyProvider.suspendNextEdit = true
                editing = Task {
                    guard let child = harness.session.geometryTopology else { return }
                    await child.setField(featureKind: "arc", fid: 7, fieldID: "Name", value: "pending arc")
                }
                isChildEditing = { harness.session.geometryTopology?.isEditing == true }
            case .mesh:
                harness.meshProvider.suspendNextEdit = true
                editing = Task {
                    guard let child = harness.session.geometryMesh else { return }
                    await child.setPatchField(featureIDs: [7], fieldID: "Name", value: "pending patch")
                }
                isChildEditing = { harness.session.geometryMesh?.isEditing == true }
            case .culvert:
                harness.culvertProvider.suspendNextEdit = true
                editing = Task {
                    guard let child = harness.session.geometryCulvert else { return }
                    await child.addPropertySet(featureKind: "barrelProperties")
                }
                isChildEditing = { harness.session.geometryCulvert?.isEditing == true }
            }
            #expect(await waitUntil { isChildEditing() })
            #expect(harness.session.isBusy)
            #expect(!(await harness.session.save(harness.initialAsset)))
            #expect(harness.modelProvider.saveRequests.isEmpty)

            harness.session.discardEdits()
            store.requestCloseTab(.editor(.geometry))
            store.discardAndCloseTab()
            #expect(harness.session.fields[GeometryChildrenParentProvider.descriptionField] == "keep this edit")
            #expect(harness.session.isBusy)
            #expect(store.openEditors == [.geometry])
            #expect(!store.showCloseTabConfirmation)

            switch child {
            case .topology: harness.topologyProvider.finishEdit(1)
            case .mesh: harness.meshProvider.finishEdit(1)
            case .culvert: harness.culvertProvider.finishEdit(1)
            }
            await editing.value

            #expect(!harness.session.isBusy)
            #expect(harness.session.modified)
            #expect(harness.session.fields[GeometryChildrenParentProvider.descriptionField] == "keep this edit")
            #expect(store.openEditors == [.geometry])
            switch child {
            case .topology: #expect(harness.session.geometryTopology?.isDirty == true)
            case .mesh: #expect(harness.session.geometryMesh?.isDirty == true)
            case .culvert: #expect(harness.session.geometryCulvert?.isDirty == true)
            }
        }
    }

    @Test @MainActor
    func lateSaveForPreviousAssetCannotAcknowledgeNewAssetChildDrafts() async throws {
        let harness = GeometryChildrenHarness(assetName: "Geometry First.hdf")
        await harness.load()
        harness.session.set(GeometryChildrenParentProvider.descriptionField, "first asset edit")
        await harness.editAllChildren(suffix: "first")

        let saving = Task { await harness.session.save(harness.initialAsset) }
        #expect(await waitUntil { harness.modelProvider.saveRequests.count == 1 })

        let secondAsset = GeometryChildrenHarness.asset("Geometry Second.hdf")
        await harness.load(secondAsset)
        harness.session.set(GeometryChildrenParentProvider.descriptionField, "second asset edit")
        harness.session.addImage(GeometryChildrenParentProvider.imageField,
            image: .init(id: "second-draft-image", name: "second.png", data: Data([7, 8])))
        await harness.editAllChildren(suffix: "second")
        let topologyState = try #require(harness.session.geometryTopology?.topologyStateForParentSave)
        let meshState = try #require(harness.session.geometryMesh?.geometryMeshStateForParentSave)
        let culvertState = try #require(harness.session.geometryCulvert?.geometryCulvertStateForParentSave)

        harness.modelProvider.finishSave(1, revision: "stale-first-asset-revision")
        #expect(!(await saving.value))

        #expect(harness.session.modelAssetID == secondAsset.id)
        #expect(harness.session.sourceFileRevision == "parent-source:\(secondAsset.name)")
        #expect(harness.session.fields[GeometryChildrenParentProvider.descriptionField] == "second asset edit")
        #expect(harness.session.images[GeometryChildrenParentProvider.imageField]?.map(\.id) == ["source-image", "second-draft-image"])
        #expect(harness.session.geometryTopology?.topologyStateForParentSave == topologyState)
        #expect(harness.session.geometryMesh?.geometryMeshStateForParentSave == meshState)
        #expect(harness.session.geometryCulvert?.geometryCulvertStateForParentSave == culvertState)
        #expect(harness.session.geometryTopology?.isDirty == true)
        #expect(harness.session.geometryMesh?.isDirty == true)
        #expect(harness.session.geometryCulvert?.isDirty == true)
        #expect(harness.session.modified)
    }

    @MainActor
    private func waitUntil(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }
}
