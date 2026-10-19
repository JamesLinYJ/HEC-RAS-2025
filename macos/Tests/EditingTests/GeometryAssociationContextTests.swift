import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class AssociationContextMeshProvider: GeometryMeshProvider {
    var projectPath = "/project/model.ras"
    var projectXML = "<Project terrain=\"A\"/>"
    var suspendNextLoad = false
    private(set) var requests: [(model: GeometryMeshModelRequest, draft: String?)] = []
    private var suspended: (CheckedContinuation<GeometryMeshSnapshot, any Error>, GeometryMeshSnapshot)?

    func modelRequest(for asset: ProjectAsset) -> GeometryMeshModelRequest {
        .init(assetPath: asset.url.path, kind: "Geometry", projectPath: projectPath, projectXml: projectXML)
    }
    func currentTopologyDraftState() -> String? { nil }
    func load(_ model: GeometryMeshModelRequest, expectedRevision: String?, draftState: String?,
              topologyDraftState: String?, selectedRegionIDs: [Int]) async throws -> GeometryMeshSnapshot {
        requests.append((model, draftState))
        let value = snapshot(model: model, draft: draftState)
        if suspendNextLoad {
            suspendNextLoad = false
            return try await withCheckedThrowingContinuation { suspended = ($0, value) }
        }
        return value
    }
    func edit(_ model: GeometryMeshModelRequest, revision: String, draftState: String,
              topologyDraftState: String?, mutation: GeometryMeshMutation,
              selectedRegionIDs: [Int]) async throws -> GeometryMeshSnapshot {
        snapshot(model: model, draft: "prepare-ledger")
    }
    func scanDegreeErrors(_ model: GeometryMeshModelRequest, revision: String, draftState: String,
                          topologyDraftState: String?, maxFacesPerNode: Int) async throws -> GeometryMeshDegreeScan {
        .init(maxFacesPerNode: maxFacesPerNode, issues: [])
    }
    func finishSuspendedLoad() {
        let pending = suspended; suspended = nil
        if let pending { pending.0.resume(returning: pending.1) }
    }
    private func snapshot(model: GeometryMeshModelRequest, draft: String?) -> GeometryMeshSnapshot {
        .init(revision: "source-revision", draftState: draft ?? "clean-ledger", topologyFingerprint: "topology",
            canEdit: true, isDirty: draft != nil, flowAreas: [],
            regions: .init(featureKind: "region", columns: [], editableFields: [], rows: []),
            selectedRegionIDs: [], patchSizing: nil, generationReport: nil,
            prepareSummary: .init(succeeded: true, failureReason: nil, softwareVersion: nil,
                startTime: nil, totalDurationSeconds: nil, prepareLog: model.projectXml),
            preparePending: draft != nil)
    }
}

struct GeometryAssociationContextTests {
    private var asset: ProjectAsset {
        .init(url: URL(fileURLWithPath: "/project/Geometries/Channel.h5"), section: .geometries)
    }

    @Test @MainActor
    func changingProjectAssociationReplaysThePendingMeshLedgerWithoutRetiringIt() async throws {
        let provider = AssociationContextMeshProvider()
        let session = GeometryMeshSession(provider: provider)
        await session.ensureLoaded(asset: asset, sourceRevision: "source-revision", topologyDraftState: nil)
        #expect(await session.requestPrepare())
        let ledger = try #require(session.geometryMeshStateForParentSave)
        provider.projectXML = "<Project terrain=\"B\"/>"

        await session.ensureLoaded(asset: asset, sourceRevision: "source-revision", topologyDraftState: nil)

        #expect(provider.requests.count == 2)
        #expect(provider.requests.last?.model.projectXml == provider.projectXML)
        #expect(provider.requests.last?.draft == ledger)
        #expect(session.geometryMeshStateForParentSave == ledger)
        #expect(session.isDirty && session.preparePending && session.canEdit)
        #expect(session.snapshot?.prepareSummary?.prepareLog == provider.projectXML)
        #expect(session.error == nil)
    }

    @Test @MainActor
    func anotherOwningProjectCannotAdoptThePendingMeshLedger() async throws {
        let provider = AssociationContextMeshProvider()
        let session = GeometryMeshSession(provider: provider)
        await session.ensureLoaded(asset: asset, sourceRevision: "source-revision", topologyDraftState: nil)
        #expect(await session.requestPrepare())
        let ledger = session.geometryMeshStateForParentSave
        provider.projectPath = "/different/project.ras"

        await session.ensureLoaded(asset: asset, sourceRevision: "source-revision", topologyDraftState: nil)

        #expect(provider.requests.count == 1)
        #expect(session.geometryMeshStateForParentSave == ledger)
        #expect(session.isDirty && session.error != nil)
    }

    @Test @MainActor
    func lateAssociationRefreshCannotReplaceTheNewerProjectContext() async throws {
        let provider = AssociationContextMeshProvider()
        let session = GeometryMeshSession(provider: provider)
        await session.ensureLoaded(asset: asset, sourceRevision: "source-revision", topologyDraftState: nil)
        #expect(await session.requestPrepare())
        provider.projectXML = "<Project terrain=\"B\"/>"
        provider.suspendNextLoad = true
        let older = Task { await session.ensureLoaded(asset: asset, sourceRevision: "source-revision", topologyDraftState: nil) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while provider.requests.count < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(provider.requests.count == 2)
        provider.projectXML = "<Project terrain=\"C\"/>"
        await session.ensureLoaded(asset: asset, sourceRevision: "source-revision", topologyDraftState: nil)
        provider.finishSuspendedLoad()
        await older.value

        #expect(provider.requests.count == 3)
        #expect(session.snapshot?.prepareSummary?.prepareLog == provider.projectXML)
        #expect(session.geometryMeshStateForParentSave == "prepare-ledger")
        #expect(session.isDirty && session.canEdit && !session.isLoading)
    }
}
