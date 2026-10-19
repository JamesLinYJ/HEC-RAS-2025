import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class ParentSaveModelProvider: ModelEditorProvider {
    static let textField = "GeometryParentSaveTests/Description"
    static let imageField = "GeometryParentSaveTests/Images"

    private(set) var saveRequests: [(asset: ProjectAsset, edits: EditorEdits)] = []
    private var saveContinuations: [Int: CheckedContinuation<EditorSaveResult, any Error>] = [:]

    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot {
        EditorSnapshot(
            fields: [Self.textField: "source: \(asset.name)"], rows: [:], samples: [:], canEdit: true,
            images: [Self.imageField: [.init(id: "source-image", name: "source.png", data: Data([1, 2]))]],
            sourceRevision: "parent-source-\(asset.name)")
    }

    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws {}

    func saveModel(_ asset: ProjectAsset, changes: EditorEdits) async throws -> EditorSaveResult {
        let request = saveRequests.count + 1
        saveRequests.append((asset, changes))
        return try await withCheckedThrowingContinuation { continuation in
            saveContinuations[request] = continuation
        }
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

private struct PendingTopologyEdit {
    let model: GeometryTopologyModelRequest
    let revision: String
    let mutation: GeometryTopologyMutation
}

@MainActor
private final class ParentSaveTopologyProvider: GeometryTopologyProvider {
    private(set) var loadRequests: [(model: GeometryTopologyModelRequest, expectedRevision: String?)] = []
    private var editRequests: [PendingTopologyEdit] = []
    private(set) var mutations: [GeometryTopologyMutation] = []
    var suspendNextEdit = false
    var editRequestCount: Int { editRequests.count }
    private(set) var filterRequestCount = 0
    private(set) var arcPointsRequestCount = 0
    var suspendNextFilter = false

    private var editContinuations: [Int: CheckedContinuation<GeometryTopologySnapshot, any Error>] = [:]
    private var filterContinuations: [Int: CheckedContinuation<GeometryTopologyFilterSnapshot, any Error>] = [:]
    private var pendingFilterRequests: [Int: GeometryTopologyFilterRequest] = [:]

    func modelRequest(for asset: ProjectAsset) -> GeometryTopologyModelRequest {
        GeometryTopologyModelRequest(assetPath: asset.url.path, kind: "Geometry", projectPath: nil, projectXml: nil)
    }

    func load(_ model: GeometryTopologyModelRequest, expectedRevision: String?) async throws -> GeometryTopologySnapshot {
        loadRequests.append((model, expectedRevision))
        let revision = expectedRevision ?? "topology-source-\(URL(fileURLWithPath: model.assetPath).lastPathComponent)"
        return Self.snapshot(revision: revision, draftState: "clean:\(revision)", isDirty: false,
            rowName: "source:\(URL(fileURLWithPath: model.assetPath).lastPathComponent)")
    }

    func edit(_ model: GeometryTopologyModelRequest, revision: String, draftState: String,
              mutation: GeometryTopologyMutation) async throws -> GeometryTopologySnapshot {
        mutations.append(mutation)
        let request = PendingTopologyEdit(model: model, revision: revision, mutation: mutation)
        editRequests.append(request)
        let index = editRequests.count
        if suspendNextEdit {
            suspendNextEdit = false
            return try await withCheckedThrowingContinuation { continuation in
                editContinuations[index] = continuation
            }
        }
        return Self.dirtySnapshot(for: request)
    }

    func inspectRecipe(_ model: GeometryTopologyModelRequest, revision: String, draftState: String,
                       controlPointFIDs: [Int], recipeText: String?) async throws -> GeometryTopologyRecipeSnapshot {
        let isMixed = controlPointFIDs.count > 1
        let sourceRecipes = controlPointFIDs.map { fid in
            GeometryTopologyControlPointRecipe(fid: fid, recipe: fid == 4 ? "BaseRecipe" : "OtherRecipe")
        }
        let rawText = recipeText ?? (isMixed ? "" : "BaseRecipe")
        return GeometryTopologyRecipeSnapshot(revision: revision,
            draftIdentity: GeometryTopologyCompletionResult.draftIdentity(for: draftState),
            controlPointFIDs: controlPointFIDs, hasSelection: !controlPointFIDs.isEmpty,
            hasMismatch: isMixed, commonRecipe: isMixed ? nil : "BaseRecipe", rawText: rawText,
            isValid: !rawText.contains("invalid"), parseIssue: rawText.contains("invalid") ? "Retained parser detail" : nil,
            steps: [], stepSchema: [], selectedRecipes: sourceRecipes)
    }

    func arcPoints(_ model: GeometryTopologyModelRequest, revision: String, draftState: String,
                   arcFID: Int) async throws -> GeometryTopologyArcPointsSnapshot {
        arcPointsRequestCount += 1
        return GeometryTopologyArcPointsSnapshot(revision: revision,
            draftIdentity: GeometryTopologyCompletionResult.draftIdentity(for: draftState), arcFID: arcFID,
            rows: [
                GeometryTopologyArcPoint(rowIndex: 0, pointKind: "start", internalPointIndex: nil,
                    endpointNodeIndex: 12, x: 0, y: 0),
                GeometryTopologyArcPoint(rowIndex: 1, pointKind: "internal", internalPointIndex: 0,
                    endpointNodeIndex: nil, x: 1, y: 1),
                GeometryTopologyArcPoint(rowIndex: 2, pointKind: "end", internalPointIndex: nil,
                    endpointNodeIndex: 13, x: 2, y: 2)
            ])
    }

    func filter(_ request: GeometryTopologyFilterRequest) async throws -> GeometryTopologyFilterSnapshot {
        filterRequestCount += 1
        let requestID = filterRequestCount
        if suspendNextFilter {
            suspendNextFilter = false
            pendingFilterRequests[requestID] = request
            return try await withCheckedThrowingContinuation { continuation in
                filterContinuations[requestID] = continuation
            }
        }
        return Self.filterSnapshot(for: request)
    }

    func save(_ model: GeometryTopologyModelRequest, revision: String,
              draftState: String) async throws -> GeometryTopologySnapshot {
        Self.snapshot(revision: revision, draftState: "clean:\(revision)", isDirty: false,
            rowName: "source:\(URL(fileURLWithPath: model.assetPath).lastPathComponent)")
    }

    func finishEdit(_ request: Int) {
        guard editRequests.indices.contains(request - 1) else { return }
        let pending = editRequests[request - 1]
        editContinuations.removeValue(forKey: request)?.resume(returning: Self.dirtySnapshot(for: pending))
    }

    func finishFilter(_ requestID: Int) {
        guard let request = pendingFilterRequests.removeValue(forKey: requestID) else { return }
        filterContinuations.removeValue(forKey: requestID)?.resume(returning: Self.filterSnapshot(for: request))
    }

    private static func filterSnapshot(for request: GeometryTopologyFilterRequest) -> GeometryTopologyFilterSnapshot {
        GeometryTopologyFilterSnapshot(revision: request.revision,
            draftIdentity: GeometryTopologyCompletionResult.draftIdentity(for: request.draftState),
            featureKind: request.featureKind,
            matchedFeatureIDs: request.featureKind == "arc" ? [7] : [4, 5],
            propertyDescriptors: [], tagDefinitions: [])
    }

    private static func dirtySnapshot(for request: PendingTopologyEdit) -> GeometryTopologySnapshot {
        let rowName = request.mutation.value ?? "edited"
        let definition: GeometryTopologyTagDefinition?
        if request.mutation.operation == "createTag", request.mutation.featureKind == "arc",
           let name = request.mutation.tagName, let type = request.mutation.tagType {
            definition = GeometryTopologyTagDefinition(id: name, type: type)
        } else {
            definition = nil
        }
        return snapshot(revision: request.revision, draftState: "draft:\(request.revision):\(rowName)",
            isDirty: true, rowName: rowName, arcTags: definition.map { [$0] } ?? [])
    }

    private static func snapshot(revision: String, draftState: String, isDirty: Bool,
                                 rowName: String, arcTags: [GeometryTopologyTagDefinition] = []) -> GeometryTopologySnapshot {
        let field = GeometryTopologyField(id: "Name", title: "Name", sourceType: "string", choices: [], readOnly: false)
        let arc = GeometryTopologyFeatureTable(featureKind: "arc", columns: [
            GeometryTopologyColumn(id: "Name", title: "Name", sourceType: "string", readOnly: false, isTag: false)
        ], editableFields: [field], rows: [
            GeometryTopologyFeatureRow(id: "arc-7", fid: 7, values: ["Name": rowName],
                startNodeID: 12, endNodeID: 13)
        ])
        let regionRows = [
            GeometryTopologyFeatureRow(id: "region-4", fid: 4, values: ["FID": "4"]),
            GeometryTopologyFeatureRow(id: "region-5", fid: 5, values: ["FID": "5"])
        ]
        let regions = GeometryTopologyFeatureTable(featureKind: "region", columns: [], editableFields: [], rows: regionRows)
        let nodes = GeometryTopologyFeatureTable(featureKind: "node", columns: [], editableFields: [], rows: [])
        return GeometryTopologySnapshot(revision: revision, draftState: draftState, canEdit: true, isDirty: isDirty,
            arcs: arc, regions: regions, nodes: nodes, arcTags: arcTags, regionTags: [], recentArcTags: [], recentRegionTags: [])
    }
}

@Suite(.serialized)
struct GeometryTopologyParentSaveTests {
    @Test
    func topologyMutationDecodesLedgerEntriesWithoutRound23Fields() throws {
        let payload = #"{"operation":"setField","featureKind":"arc","featureIDs":[7],"fieldID":"Name","value":"legacy"}"#
        let mutation = try JSONDecoder().decode(GeometryTopologyMutation.self, from: Data(payload.utf8))

        #expect(mutation.operation == "setField")
        #expect(mutation.featureIDs == [7])
        #expect(!mutation.applyToSelectedOnly)
        #expect(mutation.arcFeatureIDs.isEmpty)
        #expect(mutation.controlPointFeatureIDs.isEmpty)
        #expect(!mutation.forceSet)
        #expect(mutation.factorText == nil)
        #expect(mutation.rawValue == nil)
    }

    @Test @MainActor
    func parentSaveSubmitsFieldImageAndOpaqueTopologyDraftTogetherThenAcknowledgesNewRevision() async throws {
        let modelProvider = ParentSaveModelProvider()
        let topologyProvider = ParentSaveTopologyProvider()
        let session = ModelEditorSession(provider: modelProvider, topologyProvider: topologyProvider)
        let asset = geometryAsset("Geometry A.hdf")
        await session.load(asset, kind: .geometry)
        await session.ensureGeometryTopologyLoaded()

        session.set(ParentSaveModelProvider.textField, "edited description")
        session.addImage(ParentSaveModelProvider.imageField,
            image: .init(id: "draft-image", name: "draft.png", data: Data([3, 4])))
        await session.geometryTopology?.setField(featureKind: "arc", fid: 7, fieldID: "Name", value: "edited arc")
        let capturedState = try #require(session.geometryTopology?.topologyStateForParentSave)

        let saving = Task { await session.save(asset) }
        #expect(await waitUntil { modelProvider.saveRequests.count == 1 })
        let request = try #require(modelProvider.saveRequests.first)
        let changes = request.edits
        #expect(request.asset == asset)
        #expect(changes.fields[ParentSaveModelProvider.textField] == "edited description")
        #expect(changes.images[ParentSaveModelProvider.imageField]?.map(\.id) == ["source-image", "draft-image"])
        #expect(changes.geometryTopologyState == capturedState)
        #expect(session.geometryTopology?.parentSaveInProgress == true)

        modelProvider.finishSave(1, revision: "geometry-revision-2")
        #expect(await saving.value)
        #expect(session.sourceFileRevision == "geometry-revision-2")
        #expect(!session.modified)
        #expect(session.geometryTopology?.isDirty == false)
        #expect(session.geometryTopology?.snapshot?.revision == "geometry-revision-2")
        #expect(session.geometryTopology?.snapshot?.arcs.rows.first?.values["Name"] == "source:Geometry A.hdf")
    }

    @Test @MainActor
    func failedParentSaveKeepsOrdinaryAndTopologyDraftsDirty() async throws {
        let modelProvider = ParentSaveModelProvider()
        let topologyProvider = ParentSaveTopologyProvider()
        let session = ModelEditorSession(provider: modelProvider, topologyProvider: topologyProvider)
        let asset = geometryAsset("Geometry Failure.hdf")
        await session.load(asset, kind: .geometry)
        await session.ensureGeometryTopologyLoaded()
        session.set(ParentSaveModelProvider.textField, "unsaved description")
        session.addImage(ParentSaveModelProvider.imageField,
            image: .init(id: "unsaved-image", name: "unsaved.png", data: Data([5, 6])))
        await session.geometryTopology?.setField(featureKind: "arc", fid: 7, fieldID: "Name", value: "unsaved arc")
        let capturedState = try #require(session.geometryTopology?.topologyStateForParentSave)

        let saving = Task { await session.save(asset) }
        #expect(await waitUntil { modelProvider.saveRequests.count == 1 })
        modelProvider.failSave(1, error: CocoaError(.fileWriteNoPermission))
        #expect(!(await saving.value))
        #expect(session.modified)
        #expect(session.fields[ParentSaveModelProvider.textField] == "unsaved description")
        #expect(session.images[ParentSaveModelProvider.imageField]?.map(\.id) == ["source-image", "unsaved-image"])
        #expect(session.geometryTopology?.isDirty == true)
        #expect(session.geometryTopology?.topologyStateForParentSave == capturedState)
        #expect(session.geometryTopology?.parentSaveInProgress == false)
    }

    @Test @MainActor
    func pendingTopologyEditBlocksParentSaveAndCountsAsWorkspaceUnsavedModelWork() async throws {
        let modelProvider = ParentSaveModelProvider()
        let topologyProvider = ParentSaveTopologyProvider()
        let session = ModelEditorSession(provider: modelProvider, topologyProvider: topologyProvider)
        let suiteName = "GeometryTopologyParentSaveTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let store = WorkspaceStore(modelProvider: modelProvider,
            recentHistoryStore: RecentProjectHistoryStore(defaults: defaults))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        store.registerEditor(session)
        let asset = geometryAsset("Geometry Pending.hdf")
        await session.load(asset, kind: .geometry)
        await session.ensureGeometryTopologyLoaded()

        topologyProvider.suspendNextEdit = true
        let editing = Task {
            await session.geometryTopology?.setField(featureKind: "arc", fid: 7, fieldID: "Name", value: "pending arc")
        }
        #expect(await waitUntil { session.hasPendingTopologyEdit && topologyProvider.editRequestCount == 1 })
        #expect(!session.modified)
        #expect(store.hasUnsavedModelEdits)
        #expect(!(await session.save(asset)))
        #expect(modelProvider.saveRequests.isEmpty)

        topologyProvider.finishEdit(1)
        await editing.value
        #expect(session.modified)
        #expect(session.geometryTopology?.isDirty == true)
        #expect(store.hasUnsavedModelEdits)
    }

    @Test @MainActor
    func mixedEmptyRecipeCanBeExplicitlyForceSet() async throws {
        let provider = ParentSaveTopologyProvider()
        let topology = GeometryTopologySession(provider: provider)
        await topology.ensureLoaded(asset: geometryAsset("Geometry Mixed Recipe.hdf"), sourceRevision: "source-r1")

        await topology.loadRecipe(controlPointFIDs: [4, 5])
        let loaded = try #require(topology.recipeEditorState)
        #expect(loaded.inspection?.hasMismatch == true)
        #expect(loaded.rawText.isEmpty)
        #expect(!loaded.isPending)

        await topology.applyRecipe(controlPointFIDs: [4, 5], forceSet: true)

        let mutation = try #require(provider.mutations.last)
        #expect(mutation.operation == "applyRecipe")
        #expect(mutation.controlPointFeatureIDs == [4, 5])
        #expect(mutation.recipeText == "")
        #expect(mutation.forceSet)
        #expect(topology.isDirty)
        #expect(!topology.hasPendingInputs)
    }

    @Test @MainActor
    func arcPointCommitReloadsRowsSoTheNextAxisCanBeEditedWithoutReselection() async throws {
        let provider = ParentSaveTopologyProvider()
        let topology = GeometryTopologySession(provider: provider)
        await topology.ensureLoaded(asset: geometryAsset("Geometry Arc Points.hdf"), sourceRevision: "source-r1")
        let arcRow = try #require(topology.snapshot?.arcs.rows.first)
        topology.select([arcRow.id], featureKind: "arc")
        await topology.loadArcPoints(arcFID: arcRow.fid)
        #expect(topology.arcPoints?.arcFID == arcRow.fid)
        #expect(provider.arcPointsRequestCount == 1)

        #expect(topology.updateArcPointInput(arcFID: arcRow.fid, rowIndex: 1, axis: .x, rawText: "1.25"))
        await topology.applyArcPointInput()
        #expect(provider.mutations.last?.axis == "X")
        #expect(provider.mutations.last?.rawValue == "1.25")
        #expect(topology.pendingArcPointInput == nil)
        #expect(topology.arcPoints?.arcFID == arcRow.fid)
        #expect(provider.arcPointsRequestCount == 2)

        #expect(topology.updateArcPointInput(arcFID: arcRow.fid, rowIndex: 1, axis: .y, rawText: "1.75"))
        await topology.applyArcPointInput()
        #expect(provider.mutations.last?.axis == "Y")
        #expect(provider.mutations.last?.rawValue == "1.75")
        #expect(topology.pendingArcPointInput == nil)
        #expect(topology.arcPoints?.arcFID == arcRow.fid)
        #expect(provider.arcPointsRequestCount == 3)
    }

    @Test @MainActor
    func explicitlyAppliedInvalidRecipeIsPersistedButUnsubmittedRawBlocksSave() async throws {
        let modelProvider = ParentSaveModelProvider()
        let topologyProvider = ParentSaveTopologyProvider()
        let session = ModelEditorSession(provider: modelProvider, topologyProvider: topologyProvider)
        let asset = geometryAsset("Geometry Invalid Recipe.hdf")
        await session.load(asset, kind: .geometry)
        await session.ensureGeometryTopologyLoaded()
        let topology = try #require(session.geometryTopology)

        await topology.loadRecipe(controlPointFIDs: [4])
        #expect(topology.updateRecipeInput("invalid retained text", controlPointFIDs: [4]))
        await topology.inspectRecipe(controlPointFIDs: [4], rawText: "invalid retained text")
        #expect(topology.recipeEditorState?.inspection?.isValid == false)
        #expect(topology.hasPendingInputs)
        #expect(!(await session.save(asset)))
        #expect(modelProvider.saveRequests.isEmpty)

        await topology.applyRecipe(controlPointFIDs: [4], forceSet: false)

        #expect(topologyProvider.mutations.last?.recipeText == "invalid retained text")
        #expect(topology.isDirty)
        #expect(!topology.hasPendingInputs)
    }

    @Test @MainActor
    func parentDiscardClearsPendingRecipeAndRejectsLateReadOnlyFilterReply() async throws {
        let modelProvider = ParentSaveModelProvider()
        let topologyProvider = ParentSaveTopologyProvider()
        let session = ModelEditorSession(provider: modelProvider, topologyProvider: topologyProvider)
        let asset = geometryAsset("Geometry Pending Tool Input.hdf")
        await session.load(asset, kind: .geometry)
        await session.ensureGeometryTopologyLoaded()
        let topology = try #require(session.geometryTopology)

        await topology.loadRecipe(controlPointFIDs: [4])
        #expect(topology.updateRecipeInput("unfinished recipe", controlPointFIDs: [4]))
        #expect(session.hasIncompleteEditorInput)
        #expect(session.hasUnsavedEditorChanges)

        topologyProvider.suspendNextFilter = true
        let filtering = Task { await topology.applyTagFilterQuery(featureKind: "arc") }
        #expect(await waitUntil { topologyProvider.filterRequestCount == 1 })

        session.discardEdits()
        #expect(!topology.hasPendingInputs)
        #expect(!session.hasIncompleteEditorInput)
        #expect(!session.hasUnsavedEditorChanges)

        topologyProvider.finishFilter(1)
        await filtering.value
        #expect(topology.tagFilterResult(for: "arc").map { _ in false } ?? true)
        #expect(!topology.hasPendingInputs)
        #expect(await session.save(asset))
        #expect(modelProvider.saveRequests.isEmpty)
    }

    @Test @MainActor
    func changingSourceTagDefinitionsClearsOnlyThatFeatureKindsFilter() async throws {
        let provider = ParentSaveTopologyProvider()
        let topology = GeometryTopologySession(provider: provider)
        await topology.ensureLoaded(asset: geometryAsset("Geometry Filter Definitions.hdf"), sourceRevision: "source-r1")
        let query = GeometryTopologyTagFilterQuery(featureKind: "arc", clauses: [
            .tag(definitionID: "Tool Category", operator: .equals, value: "East")
        ])
        let regionQuery = GeometryTopologyTagFilterQuery(featureKind: "region", clauses: [
            .tag(definitionID: "Tool Region Kind", operator: .equals, value: "Outer")
        ])
        topology.updateTagFilterQuery(query)
        topology.updateTagFilterQuery(regionQuery)
        provider.suspendNextFilter = true
        let filtering = Task { await topology.applyTagFilterQuery(featureKind: "arc") }
        #expect(await waitUntil { provider.filterRequestCount == 1 })
        #expect(!topology.isDirty)

        await topology.createTag(featureKind: "arc", name: "New Source Definition", type: "String")

        #expect(topology.isDirty)
        #expect(topology.tagFilterQuery(for: "arc").clauses.isEmpty)
        #expect(topology.tagFilterResult(for: "arc").map { _ in false } ?? true)
        #expect(!topology.tagFilterResultIsCurrent(for: "arc"))
        #expect(topology.tagFilterQuery(for: "region") == regionQuery)
        provider.finishFilter(1)
        await filtering.value
        #expect(topology.tagFilterResult(for: "arc").map { _ in false } ?? true)
    }

    @Test @MainActor
    func discardWaitsForPendingTopologyEditAndModelSwitchIgnoresLateReplies() async throws {
        let modelProvider = ParentSaveModelProvider()
        let topologyProvider = ParentSaveTopologyProvider()
        let session = ModelEditorSession(provider: modelProvider, topologyProvider: topologyProvider)
        let firstAsset = geometryAsset("Geometry First.hdf")
        await session.load(firstAsset, kind: .geometry)
        await session.ensureGeometryTopologyLoaded()

        topologyProvider.suspendNextEdit = true
        let discardedEdit = Task {
            await session.geometryTopology?.setField(featureKind: "arc", fid: 7, fieldID: "Name", value: "late after discard")
        }
        #expect(await waitUntil { session.hasPendingTopologyEdit && topologyProvider.editRequestCount == 1 })
        session.discardEdits()
        #expect(session.hasPendingTopologyEdit)
        #expect(topologyProvider.loadRequests.count == 1)
        topologyProvider.finishEdit(1)
        await discardedEdit.value
        #expect(session.modified && session.geometryTopology?.isDirty == true)
        session.discardEdits()
        #expect(await waitUntil {
            topologyProvider.loadRequests.count == 2 && session.geometryTopology?.snapshot?.revision == "parent-source-Geometry First"
                && session.geometryTopology?.isLoading == false
        })
        #expect(session.geometryTopology?.isDirty == false)
        #expect(session.geometryTopology?.snapshot?.arcs.rows.first?.values["Name"] == "source:Geometry First.hdf")
        #expect(!session.modified)

        topologyProvider.suspendNextEdit = true
        let switchedEdit = Task {
            await session.geometryTopology?.setField(featureKind: "arc", fid: 7, fieldID: "Name", value: "late after switch")
        }
        #expect(await waitUntil { session.hasPendingTopologyEdit && topologyProvider.editRequestCount == 2 })

        let secondAsset = geometryAsset("Geometry Second.hdf")
        await session.load(secondAsset, kind: .geometry)
        await session.ensureGeometryTopologyLoaded()
        #expect(session.geometryTopology?.snapshot?.revision == "parent-source-Geometry Second")
        #expect(session.fields[ParentSaveModelProvider.textField] == "source: Geometry Second")

        topologyProvider.finishEdit(2)
        await switchedEdit.value
        #expect(session.geometryTopology?.snapshot?.revision == "parent-source-Geometry Second")
        #expect(session.geometryTopology?.snapshot?.arcs.rows.first?.values["Name"] == "source:Geometry Second.hdf")
        #expect(session.geometryTopology?.isDirty == false)
        #expect(!session.modified)
    }

    @MainActor
    private func geometryAsset(_ name: String) -> ProjectAsset {
        ProjectAsset(url: URL(fileURLWithPath: "/task-fixture/\(name)"), section: .geometries)
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}
