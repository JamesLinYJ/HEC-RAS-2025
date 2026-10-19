import Foundation
import Testing
import RASWorkspaceCore
@testable import HECRAS2025

@MainActor
private final class LeaseObservingMapResultProvider: MapResultChartProvider {
    let response: MapResultChartSources
    private(set) var loadCount = 0
    private(set) var requestedMaps: [MapResultChartMapRequest] = []
    private(set) var selectionCount = 0

    init(response: MapResultChartSources) { self.response = response }

    func loadSources(map: MapResultChartMapRequest,
                     selectionOverrides: [MapResultSelectionOverride]) async throws -> MapResultChartSources {
        loadCount += 1
        requestedMaps.append(map)
        return response
    }

    func selectSources(map: MapResultChartMapRequest, expectedContextToken: String,
                       currentSelectionOverrides: [MapResultSelectionOverride],
                       selectionOverrides: [MapResultSelectionOverride]) async throws -> MapResultChartSources {
        selectionCount += 1
        return response
    }

    func compute(_ request: MapResultChartSampleLineRequest,
                 progress: @escaping @Sendable (BackendProgressUpdate) -> Void) async throws -> MapResultChartSeries {
        throw MapResultLeaseTestError.unusedOperation
    }
}

private enum MapResultLeaseTestError: Error { case unusedOperation }

@MainActor
private final class MapResultLeaseReadGate {
    var canRead = true
    var leaseIsCurrent = true
}

struct MapResultSourceLeaseTests {
    @Test @MainActor
    func sourceLeaseBlocksRefreshAndSelectionWritesWhileRetainingCachedRows() async {
        let map = MapResultChartMapRequest(projectPath: "/fixture/project.ras",
            projectXml: "<Project/>", projectXmlSHA: "project-xml-sha",
            mapID: "00000000-0000-0000-0000-000000000001", mapIndex: 0,
            mapName: "Project", mapType: "Project", expectedVisualizationRevision: "vis-sha")
        let result = MapResultChartSourceChoice(resultPath: "/fixture/Results/run.h5",
            revision: "RESULT-SHA", resultName: "Run", planName: "Plan", endTime: nil,
            isComputing: false)
        let locator = CatalogTreeNodeLocator(rootName: "Layers", nodeType: "MultiResult",
            nodeName: "Plan", nodePath: [0], assetID: "/fixture/Plans/Plan.h5")
        let node = MapResultChartActiveNode(node: locator, nodeKind: "MultiResult", name: "Plan",
            selections: [.init(selectionIndex: 0, selectionMode: .latest,
                selectedResult: result, choices: [result])], selectedMapType: "Depth", profileIndex: nil)
        let sources = MapResultChartSources(projectPath: map.projectPath,
            projectRevision: "project-revision", mapID: map.mapID, mapIndex: map.mapIndex,
            mapName: map.mapName, mapType: map.mapType, projectXmlSHA: map.projectXmlSHA,
            visualizationRevision: map.expectedVisualizationRevision,
            contextToken: "source-context", activeNodes: [node])
        let provider = LeaseObservingMapResultProvider(response: sources)
        let session = MapResultSourcesSession(provider: provider)
        let gate = MapResultLeaseReadGate()
        session.configure(map: map, identity: "project-session/map-1", selectionOverrides: [],
            canReadSource: { gate.canRead }, isCurrent: { true })

        #expect(await session.loadSources())
        #expect(provider.loadCount == 1)
        let cached = session.sources
        #expect(cached == sources)

        gate.canRead = false
        #expect(session.sourceReadsBlocked)
        #expect(!(await session.loadSources(force: true)))
        await session.setSelection(nodeID: node.id, selectionIndex: 0, mode: .previous)
        await session.addSelection(nodeID: node.id)
        session.suspendSourceReads()

        #expect(provider.loadCount == 1, "A blocked refresh must not reread a Result source.")
        #expect(provider.selectionCount == 0, "Selection writes must not enter the provider during the lease.")
        #expect(session.sources == cached, "Suspending reads keeps the last accepted source snapshot visible.")
        #expect(session.errorMessage == L10n.text(
            "Result source reads are paused during an active compute or initial-condition update."))
    }

    @Test @MainActor
    func activeComputeLeaseRefreshUsesExactH5AndHdfPathsWithoutResettingLiveSourceState() async {
        let projectSessionID = UUID(uuidString: "9B06886D-5CB6-4C18-84E8-4CA13A744E04")!
        let editorID = UUID(uuidString: "B14F7F87-3C52-4B65-835A-E703BDE44C57")!
        let runID = "C1DBA871-92D6-4719-93B4-85E566A24AAA"
        let map = MapResultChartMapRequest(projectPath: "/fixture/project.ras",
            projectXml: "<Project/>", projectXmlSHA: "project-xml-sha",
            mapID: "00000000-0000-0000-0000-000000000001", mapIndex: 0,
            mapName: "Project", mapType: "Project", expectedVisualizationRevision: "vis-sha")
        let result = MapResultChartSourceChoice(resultPath: "/fixture/Results/run.h5",
            revision: "RESULT-SHA", resultName: "Run", planName: "Plan", endTime: nil,
            isComputing: false)
        let locator = CatalogTreeNodeLocator(rootName: "Layers", nodeType: "MultiResult",
            nodeName: "Plan", nodePath: [0], assetID: "/fixture/Plans/Plan.p02")
        let node = MapResultChartActiveNode(node: locator, nodeKind: "MultiResult", name: "Plan",
            selections: [.init(selectionIndex: 0, selectionMode: .latest,
                selectedResult: result, choices: [result])], selectedMapType: "Depth", profileIndex: 0)
        let sources = MapResultChartSources(projectPath: map.projectPath,
            projectRevision: "project-revision", mapID: map.mapID, mapIndex: map.mapIndex,
            mapName: map.mapName, mapType: map.mapType, projectXmlSHA: map.projectXmlSHA,
            visualizationRevision: map.expectedVisualizationRevision,
            contextToken: "source-context", activeNodes: [node])
        let provider = LeaseObservingMapResultProvider(response: sources)
        let session = MapResultSourcesSession(provider: provider)
        let gate = MapResultLeaseReadGate()
        session.configure(map: map, identity: "project-session/map-1",
            projectSessionID: projectSessionID, selectionOverrides: [],
            canReadSource: { gate.canRead }, isCurrent: { true })
        #expect(await session.loadSources())

        let capture = WorkspaceResultComputeCapture(projectSessionID: projectSessionID,
            editorID: editorID, operationOwnerToken: "owner-1", operationContextID: "context-1",
            projectPath: map.projectPath, projectRevision: "project-revision",
            projectXmlFingerprint: map.projectXmlSHA,
            planPath: "/fixture/Plans/Plan.p02", planRevision: "PLAN-SHA")
        let entry = WorkspaceResultComputeEntry(runID: runID, projectSessionID: projectSessionID,
            editorID: editorID, operationOwnerToken: capture.operationOwnerToken,
            operationContextID: capture.operationContextID, projectPath: capture.projectPath,
            projectRevision: capture.projectRevision, projectXmlFingerprint: capture.projectXmlFingerprint,
            planPath: capture.planPath, planRevision: capture.planRevision,
            resultPath: "/fixture/Results/active.hdf", resultName: "Active",
            resultRevision: nil, status: .running, fraction: 0.5, message: nil,
            taskName: "Solving", failureReason: nil)
        let lease = MapResultComputeReadLease(projectSessionID: projectSessionID.uuidString,
            runID: runID, projectPath: capture.projectPath,
            protectedSourcePaths: ["/fixture/Geometries/compute.h5", entry.resultPath],
            callbackResultPath: entry.resultPath)

        gate.canRead = false
        session.beginPlanCompute(capture)
        session.acceptPlanComputeEntry(entry)
        #expect(session.liveComputeEntry == entry)
        let refreshed = await session.refreshHistoricalResultsDuringCompute(
            lease: lease, capture: capture, entry: entry,
            readIsCurrent: { gate.leaseIsCurrent })
        #expect(refreshed?.map.computeReadLease == lease)
        #expect(provider.requestedMaps.count == 2)
        #expect(provider.requestedMaps[1].computeReadLease == lease,
            "The historical read is sent only with the exact current writer-path lease.")
        #expect(session.liveComputeEntry == entry,
            "A leased historical refresh preserves the active logical compute selection.")
        #expect(session.selectionOverrides.isEmpty,
            "Refreshing historical sources does not replace per-map selection overrides.")

        gate.leaseIsCurrent = false
        let stale = await session.refreshHistoricalResultsDuringCompute(
            lease: lease, capture: capture, entry: entry,
            readIsCurrent: { gate.leaseIsCurrent })
        #expect(stale == nil)
        #expect(provider.requestedMaps.count == 2,
            "A stale Store lease cannot start a second Project/HDF source read.")
        session.close()
    }

    @Test
    func computeReadLeaseAcceptsOnlyExactH5AndHdfSourcePaths() {
        let projectSessionID = UUID(uuidString: "9B06886D-5CB6-4C18-84E8-4CA13A744E04")!
        let editorID = UUID(uuidString: "B14F7F87-3C52-4B65-835A-E703BDE44C57")!
        let runID = "C1DBA871-92D6-4719-93B4-85E566A24AAA"
        let map = MapResultChartMapRequest(projectPath: "/tmp/lease/project.ras",
            projectXml: "<Project/>", projectXmlSHA: "project-xml-sha",
            mapID: "00000000-0000-0000-0000-000000000001", mapIndex: 0,
            mapName: "Project", mapType: "Project", expectedVisualizationRevision: "vis-sha")
        let capture = WorkspaceResultComputeCapture(projectSessionID: projectSessionID,
            editorID: editorID, operationOwnerToken: "owner-1", operationContextID: "context-1",
            projectPath: map.projectPath, projectRevision: "project-revision",
            projectXmlFingerprint: map.projectXmlSHA,
            planPath: "/tmp/lease/Plans/Plan.p02", planRevision: "PLAN-SHA")

        for extensionName in ["h5", "hdf"] {
            let resultPath = "/tmp/lease/Results/active.\(extensionName)"
            let entry = WorkspaceResultComputeEntry(runID: runID, projectSessionID: projectSessionID,
                editorID: editorID, operationOwnerToken: capture.operationOwnerToken,
                operationContextID: capture.operationContextID, projectPath: capture.projectPath,
                projectRevision: capture.projectRevision, projectXmlFingerprint: capture.projectXmlFingerprint,
                planPath: capture.planPath, planRevision: capture.planRevision,
                resultPath: resultPath, resultName: "Active", resultRevision: nil,
                status: .running, fraction: 0.5, message: nil, taskName: nil, failureReason: nil)
            let lease = MapResultComputeReadLease(projectSessionID: projectSessionID.uuidString,
                runID: runID, projectPath: capture.projectPath,
                protectedSourcePaths: ["/tmp/lease/Geometries/geometry.h5", resultPath],
                callbackResultPath: resultPath)
            #expect(lease.validates(map: map, capture: capture, entry: entry),
                "A protected \(extensionName) HDF is accepted when it is exactly bound to this run.")
            let unsupported = MapResultComputeReadLease(projectSessionID: lease.projectSessionID,
                runID: lease.runID, projectPath: lease.projectPath,
                protectedSourcePaths: lease.protectedSourcePaths,
                callbackResultPath: "/tmp/lease/Results/active.bin")
            #expect(!unsupported.validates(map: map, capture: capture, entry: entry))
        }
    }
}
