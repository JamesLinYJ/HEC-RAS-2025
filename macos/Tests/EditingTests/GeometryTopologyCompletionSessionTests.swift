import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class TopologyCompletionTestProvider: GeometryTopologyProvider {
    private(set) var mutations: [GeometryTopologyMutation] = []
    var loadSnapshot: GeometryTopologySnapshot

    init(loadSnapshot: GeometryTopologySnapshot) {
        self.loadSnapshot = loadSnapshot
    }

    func modelRequest(for asset: ProjectAsset) -> GeometryTopologyModelRequest {
        GeometryTopologyModelRequest(assetPath: asset.url.path, kind: "Geometry", projectPath: nil, projectXml: nil)
    }

    func load(_ model: GeometryTopologyModelRequest, expectedRevision: String?) async throws -> GeometryTopologySnapshot {
        loadSnapshot
    }

    func edit(_ model: GeometryTopologyModelRequest, revision: String, draftState: String,
              mutation: GeometryTopologyMutation) async throws -> GeometryTopologySnapshot {
        mutations.append(mutation)
        let canUndo = mutation.operation != "undo"
        let canRedo = mutation.operation == "undo"
        let nextDraft = "{\"assetPath\":\"/task-fixture/Geometry.hdf\",\"revision\":\"\(revision)\",\"mutations\":[\"\(mutation.operation)\"],\"redoMutations\":[]}"
        return Self.snapshot(revision: revision, draftState: nextDraft, canUndo: canUndo, canRedo: canRedo)
    }

    func save(_ model: GeometryTopologyModelRequest, revision: String,
              draftState: String) async throws -> GeometryTopologySnapshot {
        Self.snapshot(revision: revision, draftState: draftState, canUndo: false, canRedo: false)
    }

    static func snapshot(revision: String = "source-r1", draftState: String = "clean-state",
                         isDirty: Bool = false,
                         validCompletionIdentity: Bool = true, completionRevision: String? = nil,
                         canUndo: Bool = false,
                         canRedo: Bool = false) -> GeometryTopologySnapshot {
        let arcRow = GeometryTopologyFeatureRow(id: "arc:7", fid: 7, values: ["FID": "7"])
        let regionRow = GeometryTopologyFeatureRow(id: "region:4", fid: 4, values: ["FID": "4"])
        let arcTable = GeometryTopologyFeatureTable(featureKind: "arc", columns: [], editableFields: [], rows: [arcRow])
        let regionTable = GeometryTopologyFeatureTable(featureKind: "region", columns: [], editableFields: [], rows: [regionRow])
        let nodeTable = GeometryTopologyFeatureTable(featureKind: "node", columns: [], editableFields: [], rows: [])
        let arcTarget = GeometryTopologyDiagnosticTarget(featureKind: "arc", fid: 7,
            tableRowID: "arc:7", mapFeatureIDs: ["arc:7"])
        let message = GeometryTopologyCompletionMessage(id: "0:TOP-17", code: "TOP-17", severity: "Warning",
            regionCompletionSeverity: "Fatal", text: "Exact retained source message",
            logData: [GeometryTopologyLogValue(key: "ArcIndex", value: "7", valueType: "Int32", integerValue: 7)],
            targets: [arcTarget])
        let identity = GeometryTopologyCompletionResult.draftIdentity(for: draftState)
        let completion = GeometryTopologyCompletionResult(sourceRevision: completionRevision ?? revision,
            draftIdentity: validCompletionIdentity ? identity : String(repeating: "0", count: 64),
            isComplete: false, messages: [message])
        return GeometryTopologySnapshot(revision: revision, draftState: draftState, canEdit: true, isDirty: isDirty,
            arcs: arcTable, regions: regionTable, nodes: nodeTable, arcTags: [], regionTags: [],
            recentArcTags: [], recentRegionTags: [], canUndo: canUndo, canRedo: canRedo, completion: completion)
    }
}

@Suite(.serialized)
struct GeometryTopologyCompletionSessionTests {
    @Test @MainActor
    func sourceAutomaticRepairOnLoadMarksTheParentDraftDirty() async {
        let sourceDraft = #"{"assetPath":"/task-fixture/Geometry.hdf","revision":"source-r1","mutations":[],"redoMutations":[],"recentArcTags":[],"recentRegionTags":[]}"#
        let provider = TopologyCompletionTestProvider(loadSnapshot: TopologyCompletionTestProvider.snapshot(
            revision: "source-r1", draftState: sourceDraft, isDirty: true))
        var parentDirtyEvents: [Bool] = []
        let session = GeometryTopologySession(provider: provider,
            onParentDraftChange: { parentDirtyEvents.append($0) })

        await session.ensureLoaded(asset: geometryAsset(), sourceRevision: "source-r1")

        #expect(session.isDirty)
        #expect(session.topologyStateForParentSave == sourceDraft)
        #expect(parentDirtyEvents.last == true)
        #expect(session.buildResultPresentation?.draftIdentity
            == GeometryTopologyCompletionResult.draftIdentity(for: sourceDraft))
    }

    @Test @MainActor
    func acknowledgementKeepsAndReportsANewSourceRepairFoundByTheFreshRead() async throws {
        let provider = TopologyCompletionTestProvider(loadSnapshot:
            TopologyCompletionTestProvider.snapshot(revision: "source-r1"))
        var parentDirtyEvents: [Bool] = []
        let session = GeometryTopologySession(provider: provider,
            onParentDraftChange: { parentDirtyEvents.append($0) })
        await session.ensureLoaded(asset: geometryAsset(), sourceRevision: "source-r1")

        let capture = try #require(session.beginParentSave())
        #expect(capture.draftState == nil)
        let repairedDraft = #"{"assetPath":"/task-fixture/Geometry.hdf","revision":"source-r2","mutations":[],"redoMutations":[],"recentArcTags":[],"recentRegionTags":[]}"#
        provider.loadSnapshot = TopologyCompletionTestProvider.snapshot(
            revision: "source-r2", draftState: repairedDraft, isDirty: true)

        await session.acknowledgeParentSave(capture, newSourceRevision: "source-r2")

        #expect(session.snapshot?.revision == "source-r2")
        #expect(session.isDirty)
        #expect(session.topologyStateForParentSave == repairedDraft)
        #expect(parentDirtyEvents.last == true)
        #expect(!session.parentSaveInProgress)
        #expect(session.buildResultPresentation?.draftIdentity
            == GeometryTopologyCompletionResult.draftIdentity(for: repairedDraft))
    }

    @Test @MainActor
    func completionKeepsExactSourcePayloadAndDiagnosticTargetIsSeparateFromTableSelection() async throws {
        let provider = TopologyCompletionTestProvider(loadSnapshot: TopologyCompletionTestProvider.snapshot())
        let session = GeometryTopologySession(provider: provider)
        await session.ensureLoaded(asset: geometryAsset(), sourceRevision: "source-r1")

        let result = try #require(session.buildResultPresentation)
        #expect(!result.succeeded)
        #expect(result.messages.first?.code == "TOP-17")
        #expect(result.messages.first?.sourceSeverity == "Warning")
        #expect(result.messages.first?.regionCompletionSeverity == "Fatal")
        #expect(result.messages.first?.text == "Exact retained source message")
        #expect(result.messages.first?.context.first?.key == "ArcIndex")
        #expect(result.messages.first?.context.first?.value == "7")
        #expect(result.messages.first?.context.first?.valueType == "Int32")
        #expect(result.messages.first?.context.first?.integerValue == 7)
        #expect(result.messages.first?.timestamp == nil)

        session.selectDiagnosticMessage("0:TOP-17")
        #expect(session.diagnosticMapFeatureIDs == ["arc:7"])
        #expect(session.selectedFeatureIDs["arc", default: []].isEmpty)
        #expect(session.diagnosticRowIDs(for: "arc") == ["arc:7"])
        let target = try #require(result.messages.first?.targets.first)
        #expect(session.canOpenDiagnosticTarget(target))
        #expect(session.openDiagnosticTarget(target) == "Arcs")
        #expect(session.selectedFeatureIDs["arc"] == ["arc:7"])
        #expect(session.diagnosticMapFeatureIDs == ["arc:7"])
        #expect(session.diagnosticMessages(featureKind: "arc", rowIDs: ["arc:7"]).map(\.id) == ["0:TOP-17"])
    }

    @Test @MainActor
    func staleCompletionIdentityIsRejectedEvenWhenItsSourceRevisionMatches() async {
        let stale = TopologyCompletionTestProvider.snapshot(validCompletionIdentity: false)
        let session = GeometryTopologySession(provider: TopologyCompletionTestProvider(loadSnapshot: stale))
        await session.ensureLoaded(asset: geometryAsset(), sourceRevision: "source-r1")

        #expect(session.snapshot?.completion == nil)
        #expect(session.buildResultPresentation == nil)
        #expect(session.error == "The topology completion result does not match the current source draft.")
    }

    @Test @MainActor
    func completionFromAnotherSourceRevisionIsRejected() async {
        let stale = TopologyCompletionTestProvider.snapshot(completionRevision: "old-source-r0")
        let session = GeometryTopologySession(provider: TopologyCompletionTestProvider(loadSnapshot: stale))
        await session.ensureLoaded(asset: geometryAsset(), sourceRevision: "source-r1")

        #expect(session.snapshot?.completion == nil)
        #expect(session.buildResultPresentation == nil)
        #expect(session.error == "The topology completion result does not match the current source draft.")
    }

    @Test
    func draftIdentityHashesExactUtf8BytesWithoutStringNormalization() {
        let composed = GeometryTopologyCompletionResult.draftIdentity(for: "é")
        let decomposed = GeometryTopologyCompletionResult.draftIdentity(for: "e\u{301}")
        #expect(composed != decomposed)
        #expect(composed.count == 64)
    }

    @Test @MainActor
    func undoRedoUseTypedHistoryMutationsAndAcceptTheReturnedCompletion() async throws {
        let provider = TopologyCompletionTestProvider(loadSnapshot:
            TopologyCompletionTestProvider.snapshot(canUndo: true))
        let session = GeometryTopologySession(provider: provider)
        await session.ensureLoaded(asset: geometryAsset(), sourceRevision: "source-r1")

        #expect(session.canUndo)
        await session.undo()
        #expect(provider.mutations.last?.operation == "undo")
        #expect(provider.mutations.last?.featureKind == "history")
        #expect(provider.mutations.last?.featureIDs == [])
        #expect(!session.canUndo && session.canRedo)
        #expect(session.buildResultPresentation?.draftIdentity == session.snapshot?.completion?.draftIdentity)

        await session.redo()
        #expect(provider.mutations.last?.operation == "redo")
        #expect(provider.mutations.last?.featureKind == "history")
        #expect(provider.mutations.last?.featureIDs == [])
        #expect(session.canUndo && !session.canRedo)
        #expect(session.buildResultPresentation?.sourceRevision == "source-r1")
    }

    @MainActor
    private func geometryAsset() -> ProjectAsset {
        ProjectAsset(url: URL(fileURLWithPath: "/task-fixture/Geometry.hdf"), section: .geometries)
    }
}
