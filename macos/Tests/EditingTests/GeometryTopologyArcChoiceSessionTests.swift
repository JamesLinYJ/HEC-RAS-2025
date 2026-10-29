import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class ArcChoiceTopologyProvider: GeometryTopologyProvider {
    private(set) var mutations: [GeometryTopologyMutation] = []
    var loadSnapshot: GeometryTopologySnapshot
    var suspendNextEdit = false
    private var pendingEdit: CheckedContinuation<GeometryTopologySnapshot, Error>?
    private var pendingEditResult: GeometryTopologySnapshot?
    private var editWaiters: [CheckedContinuation<Void, Never>] = []

    init(loadSnapshot: GeometryTopologySnapshot) {
        self.loadSnapshot = loadSnapshot
    }

    func modelRequest(for asset: ProjectAsset) -> GeometryTopologyModelRequest {
        GeometryTopologyModelRequest(assetPath: asset.url.path, kind: "Geometry",
            projectPath: nil, projectXml: nil)
    }

    func load(_ model: GeometryTopologyModelRequest, expectedRevision: String?) async throws -> GeometryTopologySnapshot {
        loadSnapshot
    }

    func edit(_ model: GeometryTopologyModelRequest, revision: String, draftState: String,
              mutation: GeometryTopologyMutation) async throws -> GeometryTopologySnapshot {
        mutations.append(mutation)
        let response = editedSnapshot(from: loadSnapshot, revision: revision, mutation: mutation,
            draftState: "draft-\(mutations.count)")
        guard suspendNextEdit else { return response }
        suspendNextEdit = false
        return try await withCheckedThrowingContinuation { continuation in
            pendingEdit = continuation
            pendingEditResult = response
            let waiters = editWaiters
            editWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func save(_ model: GeometryTopologyModelRequest, revision: String,
              draftState: String) async throws -> GeometryTopologySnapshot {
        loadSnapshot
    }

    func waitForPendingEdit() async {
        if pendingEdit != nil { return }
        await withCheckedContinuation { continuation in editWaiters.append(continuation) }
    }

    func resumePendingEdit() {
        guard let pendingEdit, let pendingEditResult else { return }
        self.pendingEdit = nil
        self.pendingEditResult = nil
        pendingEdit.resume(returning: pendingEditResult)
    }

    private func editedSnapshot(from source: GeometryTopologySnapshot, revision: String,
                                mutation: GeometryTopologyMutation, draftState: String) -> GeometryTopologySnapshot {
        let selected = Set(mutation.featureIDs)
        let arcs = source.arcs.rows.map { row -> GeometryTopologyFeatureRow in
            guard selected.contains(row.fid) else { return row }
            var values = row.values
            if mutation.operation == "forceSetArcChoice", let fieldID = mutation.fieldID, let value = mutation.value {
                values[fieldID] = value
            } else if mutation.operation == "forceResetArcBias" {
                values["Bias"] = "NaN"
            }
            return GeometryTopologyFeatureRow(id: row.id, fid: row.fid, values: values,
                x: row.x, y: row.y, startNodeID: row.startNodeID, endNodeID: row.endNodeID)
        }
        return Self.snapshot(revision: revision, draftState: draftState, arcs: arcs,
            isDirty: true, canUndo: true)
    }

    static func snapshot(revision: String, draftState: String,
                         arcs: [GeometryTopologyFeatureRow]? = nil,
                         isDirty: Bool = false, canUndo: Bool = false) -> GeometryTopologySnapshot {
        let arcRows = arcs ?? defaultArcs
        return GeometryTopologySnapshot(revision: revision, draftState: draftState, canEdit: true, isDirty: isDirty,
            arcs: GeometryTopologyFeatureTable(featureKind: "arc", columns: [], editableFields: [], rows: arcRows),
            regions: GeometryTopologyFeatureTable(featureKind: "region", columns: [], editableFields: [], rows: []),
            nodes: GeometryTopologyFeatureTable(featureKind: "node", columns: [], editableFields: [], rows: []),
            arcTags: [], regionTags: [], recentArcTags: [], recentRegionTags: [], canUndo: canUndo)
    }

    private static let defaultArcs = [
        GeometryTopologyFeatureRow(id: "arc:11", fid: 11,
            values: ["ConstrainStretching": "Constrained", "LaplaceBC": "ZeroFlux", "Bias": "1.5"]),
        GeometryTopologyFeatureRow(id: "arc:17", fid: 17,
            values: ["ConstrainStretching": "Floating", "LaplaceBC": "Dirichlet", "Bias": "2.5"]),
        GeometryTopologyFeatureRow(id: "arc:23", fid: 23,
            values: ["ConstrainStretching": "Floating", "LaplaceBC": "Default", "Bias": "3"])
    ]
}

@Suite(.serialized)
struct GeometryTopologyArcChoiceSessionTests {
    @Test @MainActor
    func forceSetAppliesTheDisplayedMixedDefaultToTheExactSelectedArcs() async {
        let provider = ArcChoiceTopologyProvider(loadSnapshot:
            ArcChoiceTopologyProvider.snapshot(revision: "source-r1", draftState: "draft-clean"))
        let session = GeometryTopologySession(provider: provider)
        await session.ensureLoaded(asset: geometryAsset(), sourceRevision: "source-r1")
        session.select(["arc:11", "arc:17"], featureKind: "arc")

        let applied = await session.forceSetArcChoice(rowIDs: ["arc:11", "arc:17"],
            fieldID: "ConstrainStretching", value: "Default")

        #expect(applied)
        #expect(provider.mutations.count == 1)
        #expect(provider.mutations[0].operation == "forceSetArcChoice")
        #expect(provider.mutations[0].featureKind == "arc")
        #expect(provider.mutations[0].featureIDs == [11, 17])
        #expect(provider.mutations[0].fieldID == "ConstrainStretching")
        #expect(provider.mutations[0].value == "Default")
        #expect(session.snapshot?.arcs.rows.filter { [11, 17].contains($0.fid) }
            .allSatisfy { $0.values["ConstrainStretching"] == "Default" } == true)
        #expect(session.snapshot?.arcs.rows.first { $0.fid == 23 }?.values["ConstrainStretching"] == "Floating")
        #expect(session.isDirty && session.canUndo)
    }

    @Test @MainActor
    func forceSetRejectsAStaleSelectionAndDiscardsAResponseAfterSelectionChanges() async {
        let provider = ArcChoiceTopologyProvider(loadSnapshot:
            ArcChoiceTopologyProvider.snapshot(revision: "source-r1", draftState: "draft-clean"))
        let session = GeometryTopologySession(provider: provider)
        await session.ensureLoaded(asset: geometryAsset(), sourceRevision: "source-r1")
        session.select(["arc:11"], featureKind: "arc")

        let staleSelectionApplied = await session.forceSetArcChoice(rowIDs: ["arc:11", "arc:17"],
            fieldID: "ConstrainStretching", value: "Default")
        #expect(!staleSelectionApplied)
        #expect(provider.mutations.isEmpty)

        session.select(["arc:11", "arc:17"], featureKind: "arc")
        provider.suspendNextEdit = true
        let operation = Task { @MainActor in
            await session.forceSetArcChoice(rowIDs: ["arc:11", "arc:17"],
                fieldID: "ConstrainStretching", value: "Default")
        }
        await provider.waitForPendingEdit()
        session.select(["arc:11"], featureKind: "arc")
        provider.resumePendingEdit()

        let selectionChangedApplied = await operation.value
        #expect(!selectionChangedApplied)
        #expect(session.snapshot?.draftState == "draft-clean")
        #expect(!session.isDirty)
    }

    @Test @MainActor
    func arcBiasClearUsesNaNAndRejectsALateResponseFromThePriorDraftOwner() async {
        let provider = ArcChoiceTopologyProvider(loadSnapshot:
            ArcChoiceTopologyProvider.snapshot(revision: "source-r1", draftState: "draft-source-r1"))
        let session = GeometryTopologySession(provider: provider)
        await session.ensureLoaded(asset: geometryAsset(), sourceRevision: "source-r1")
        session.select(["arc:11", "arc:17"], featureKind: "arc")
        #expect(await session.forceResetArcBias(rowIDs: ["arc:11", "arc:17"]))
        #expect(provider.mutations.last?.operation == "forceResetArcBias")
        #expect(provider.mutations.last?.fieldID == "Bias")
        #expect(session.snapshot?.arcs.rows.filter { [11, 17].contains($0.fid) }
            .allSatisfy { $0.values["Bias"] == "NaN" } == true)

        provider.suspendNextEdit = true
        let operation = Task { @MainActor in
            await session.forceSetArcChoice(rowIDs: ["arc:11", "arc:17"],
                fieldID: "LaplaceBC", value: "ZeroFlux")
        }
        await provider.waitForPendingEdit()

        session.invalidate()
        // Keep the same asset and source revision while replacing only the
        // child draft. The pending response must be rejected because its
        // captured draft identity is stale, even though the source still
        // appears unchanged.
        provider.loadSnapshot = ArcChoiceTopologyProvider.snapshot(revision: "source-r1", draftState: "draft-source-r1-newer")
        await session.ensureLoaded(asset: geometryAsset(), sourceRevision: "source-r1")
        provider.resumePendingEdit()

        let priorOwnerApplied = await operation.value
        #expect(!priorOwnerApplied)
        #expect(session.snapshot?.revision == "source-r1")
        #expect(session.snapshot?.draftState == "draft-source-r1-newer")
        #expect(session.snapshot?.arcs.rows.map(\.id) == ["arc:11", "arc:17", "arc:23"])
    }

    @MainActor
    private func geometryAsset(path: String = "/task-fixture/Geometry.hdf") -> ProjectAsset {
        ProjectAsset(url: URL(fileURLWithPath: path), section: .geometries)
    }
}
