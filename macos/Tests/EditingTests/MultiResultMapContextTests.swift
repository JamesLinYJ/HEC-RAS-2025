import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class MultiResultSelectionRecordingProvider: MapResultChartProvider {
    private(set) var response: MapResultChartSources
    private(set) var selectionRequests: [[MapResultSelectionOverride]] = []

    init(response: MapResultChartSources) { self.response = response }

    func loadSources(map: MapResultChartMapRequest,
                     selectionOverrides: [MapResultSelectionOverride]) async throws -> MapResultChartSources {
        response
    }

    func selectSources(map: MapResultChartMapRequest, expectedContextToken: String,
                       currentSelectionOverrides: [MapResultSelectionOverride],
                       selectionOverrides: [MapResultSelectionOverride]) async throws -> MapResultChartSources {
        guard response.contextToken == expectedContextToken else {
            throw MultiResultSelectionTestError.staleContext
        }
        selectionRequests.append(selectionOverrides)
        let updatedNodes = response.activeNodes.map { node in
            let requested = selectionOverrides.filter { $0.nodeIdentity == node.id }
                .sorted { $0.selectionIndex < $1.selectionIndex }
            guard node.nodeKind == "MultiResult", let template = node.selections.first else { return node }
            let slots = requested.map { item -> MapResultChartSelectionSlot in
                let selected: MapResultChartSourceChoice?
                switch item.mode {
                case .latest: selected = template.choices.first
                case .previous: selected = template.choices.dropFirst().first
                case .explicit:
                    selected = template.choices.first {
                        MultiResultContextRouteProjection.canonicalPath($0.resultPath)
                            == MultiResultContextRouteProjection.canonicalPath(item.resultPath ?? "")
                            && $0.revision.caseInsensitiveCompare(item.resultRevision ?? "") == .orderedSame
                    }
                }
                return MapResultChartSelectionSlot(selectionIndex: item.selectionIndex,
                    selectionMode: item.mode, selectedResult: selected, choices: template.choices)
            }
            return MapResultChartActiveNode(node: node.node, nodeKind: node.nodeKind, name: node.name,
                selections: slots, selectedMapType: node.selectedMapType, profileIndex: node.profileIndex)
        }
        response = MapResultChartSources(projectPath: response.projectPath,
            projectRevision: response.projectRevision, mapID: response.mapID,
            mapIndex: response.mapIndex, mapName: response.mapName, mapType: response.mapType,
            projectXmlSHA: response.projectXmlSHA, visualizationRevision: response.visualizationRevision,
            contextToken: "context-\(selectionRequests.count)", activeNodes: updatedNodes)
        return response
    }

    func compute(_ request: MapResultChartSampleLineRequest,
                 progress: @escaping @Sendable (BackendProgressUpdate) -> Void) async throws -> MapResultChartSeries {
        throw MultiResultSelectionTestError.unusedOperation
    }
}

private enum MultiResultSelectionTestError: Error { case staleContext, unusedOperation }

struct MultiResultMapContextTests {
    @Test @MainActor
    func latestUsesOnlyTheActualNewResultForItsExactOwnerAndProject() throws {
        let sessionID = UUID()
        let planPath = "/fixture/Plans/Plan A.h5"
        let callbackResultPath = "/fixture/Results/solver-created-run.h5"
        let node = mapNode(planPath: planPath, planName: "Plan A")
        let oldChoice = sourceChoice(path: "/fixture/Results/previous.h5", name: "Previous")
        let actualEntry = liveEntry(projectSessionID: sessionID, planPath: planPath,
            resultPath: callbackResultPath, resultName: "Source callback name",
            runID: "run-from-source", resultRevision: nil)

        let projected = try #require(MultiResultSelectionProjection.transientLatestEntry(
            for: node, choices: [oldChoice], projectSessionID: sessionID,
            isPlanComputeActive: true, liveEntries: [callbackResultPath: actualEntry]))
        #expect(projected.resultPath == MultiResultContextRouteProjection.canonicalPath(callbackResultPath))
        #expect(projected.resultName == "Source callback name")
        #expect(projected.runID == "run-from-source")
        #expect(projected.resultRevision == nil,
            "The source callback row remains display-only until a stable Result SHA is available.")

        #expect(MultiResultSelectionProjection.transientLatestEntry(
            for: node, choices: [oldChoice], projectSessionID: UUID(),
            isPlanComputeActive: true, liveEntries: [callbackResultPath: actualEntry]) == nil,
            "A project switch must not carry a live Result into the new session.")
        #expect(MultiResultSelectionProjection.transientLatestEntry(
            for: node, choices: [oldChoice], projectSessionID: sessionID,
            isPlanComputeActive: false, liveEntries: [callbackResultPath: actualEntry]) == nil)
    }

    @Test @MainActor
    func latestDoesNotBorrowAnotherPlanOrTurnAChoiceIntoATransientRow() {
        let sessionID = UUID()
        let node = mapNode(planPath: "/fixture/Plans/Plan A.h5", planName: "Same display name")
        let choice = sourceChoice(path: "/fixture/Results/current.h5", name: "Current")
        let otherPlanEntry = liveEntry(projectSessionID: sessionID,
            planPath: "/fixture/Plans/Plan B.h5", resultPath: "/fixture/Results/new.h5",
            resultName: "Other plan result", runID: "other-plan-run", resultRevision: nil)
        #expect(MultiResultSelectionProjection.transientLatestEntry(
            for: node, choices: [choice], projectSessionID: sessionID,
            isPlanComputeActive: true, liveEntries: [otherPlanEntry.resultPath: otherPlanEntry]) == nil,
            "A matching Plan name does not establish ownership.")

        let representedEntry = liveEntry(projectSessionID: sessionID,
            planPath: "/fixture/Plans/Plan A.h5", resultPath: choice.resultPath,
            resultName: "Current", runID: "represented-run", resultRevision: nil)
        #expect(MultiResultSelectionProjection.transientLatestEntry(
            for: node, choices: [choice], projectSessionID: sessionID,
            isPlanComputeActive: true, liveEntries: [representedEntry.resultPath: representedEntry]) == nil,
            "A callback path already present in source choices remains represented by that exact choice.")

        let other = liveEntry(projectSessionID: sessionID,
            planPath: "/fixture/Plans/Plan A.h5", resultPath: "/fixture/Results/other.h5",
            resultName: "Other run", runID: "second-run", resultRevision: nil)
        let anotherUnrepresented = liveEntry(projectSessionID: sessionID,
            planPath: "/fixture/Plans/Plan A.h5", resultPath: "/fixture/Results/another.h5",
            resultName: "Another run", runID: "third-run", resultRevision: nil)
        #expect(MultiResultSelectionProjection.transientLatestEntry(
            for: node, choices: [choice], projectSessionID: sessionID,
            isPlanComputeActive: true,
            liveEntries: [other.resultPath: other, anotherUnrepresented.resultPath: anotherUnrepresented]) == nil,
            "Two unrepresented live identities cannot be guessed into the Latest slot.")
    }

    @Test @MainActor
    func activeGroupRoutingUsesUniqueExactResultMembership() {
        let resultPath = "/fixture/Results/selected.h5"
        let first = mapNode(planPath: "/fixture/Plans/Plan A.h5", planName: "Duplicate")
        let matching = mapNode(planPath: "/fixture/Plans/Plan B.h5", planName: "Duplicate",
            selectedResultPath: resultPath)
        let duplicateMatch = mapNode(planPath: "/fixture/Plans/Plan C.h5", planName: "Duplicate",
            selectedResultPath: resultPath)

        #expect(MultiResultContextRouteProjection.uniquelySelectedGroupID(
            for: resultPath, among: [first, matching]) == matching.id)
        #expect(MultiResultContextRouteProjection.uniquelySelectedGroupID(
            for: resultPath, among: [matching, duplicateMatch]) == nil,
            "Multiple actual map groups require an explicit group selection.")
        #expect(MultiResultContextRouteProjection.uniquelySelectedGroupID(
            for: "/fixture/Results/not-selected.h5", among: [first, matching]) == nil)
    }

    @Test @MainActor
    func catalogFallbackRoutesByExactPlanPathAndKeepsAmbiguousGroupsExplicit() {
        let sameNameDifferentPlan = mapNode(planPath: "/fixture/Plans/Other.h5", planName: "Shared name")
        let exactPlanGroup = mapNode(planPath: "/fixture/Plans/Owner.h5", planName: "Shared name")
        let duplicateExactGroup = mapNode(planPath: "/fixture/Plans/Owner.h5", planName: "Second label")

        let exactMatches = MultiResultContextRouteProjection.activeGroups(
            forPlanAssetID: "/fixture/Plans/./Owner.h5",
            among: [sameNameDifferentPlan, exactPlanGroup])
        #expect(exactMatches.map(\.id) == [exactPlanGroup.id],
            "Catalog fallback uses canonical Plan identity, never a matching display name.")

        let ambiguousMatches = MultiResultContextRouteProjection.activeGroups(
            forPlanAssetID: "/fixture/Plans/Owner.h5",
            among: [exactPlanGroup, duplicateExactGroup])
        #expect(ambiguousMatches.map(\.id) == [exactPlanGroup.id, duplicateExactGroup.id],
            "Multiple groups owned by the same exact Plan must remain user-selectable.")
        #expect(MultiResultContextRouteProjection.activeGroups(
            forPlanAssetID: "/fixture/Plans/Missing.h5",
            among: [sameNameDifferentPlan, exactPlanGroup]).isEmpty)
    }

    @Test @MainActor
    func addAndRemoveSelectionsPreserveExactSourceOrderAndMinimumOneRow() async {
        let map = MapResultChartMapRequest(projectPath: "/fixture/project.ras",
            projectXml: "<Project/>", projectXmlSHA: "project-xml-sha",
            mapID: "00000000-0000-0000-0000-000000000001", mapIndex: 0,
            mapName: "Project", mapType: "Project", expectedVisualizationRevision: "vis-sha")
        let choices = [
            sourceChoice(path: "/fixture/Results/latest.h5", name: "Latest"),
            sourceChoice(path: "/fixture/Results/previous.h5", name: "Previous"),
            sourceChoice(path: "/fixture/Results/unselected.h5", name: "Unselected")
        ]
        let locator = CatalogTreeNodeLocator(rootName: "Layers", nodeType: "MultiResult",
            nodeName: "Plan", nodePath: [0], assetID: "/fixture/Plans/Plan.h5")
        let node = MapResultChartActiveNode(node: locator, nodeKind: "MultiResult", name: "Plan",
            selections: [
                .init(selectionIndex: 0, selectionMode: .latest, selectedResult: choices[0], choices: choices),
                .init(selectionIndex: 1, selectionMode: .previous, selectedResult: choices[1], choices: choices)
            ], selectedMapType: "Depth", profileIndex: 3)
        let initial = MapResultChartSources(projectPath: map.projectPath,
            projectRevision: "project-revision", mapID: map.mapID, mapIndex: map.mapIndex,
            mapName: map.mapName, mapType: map.mapType, projectXmlSHA: map.projectXmlSHA,
            visualizationRevision: map.expectedVisualizationRevision,
            contextToken: "context-initial", activeNodes: [node])
        let provider = MultiResultSelectionRecordingProvider(response: initial)
        let session = MapResultSourcesSession(provider: provider)
        session.configure(map: map, identity: "project-session/map-1", selectionOverrides: [],
            isCurrent: { true })

        #expect(await session.loadSources())
        await session.addSelection(nodeID: node.id)
        #expect(provider.selectionRequests.count == 1)
        let afterAdd = provider.selectionRequests[0]
        #expect(afterAdd.map(\.selectionIndex) == [0, 1, 2])
        #expect(afterAdd.map(\.mode) == [.latest, .previous, .explicit])
        #expect(afterAdd[2].resultPath == choices[2].resultPath)
        #expect(afterAdd[2].resultRevision == choices[2].revision)

        await session.removeSelection(nodeID: node.id, selectionIndex: 1)
        #expect(provider.selectionRequests.count == 2)
        let afterRemove = provider.selectionRequests[1]
        #expect(afterRemove.map(\.selectionIndex) == [0, 1])
        #expect(afterRemove.map(\.mode) == [.latest, .explicit])
        #expect(afterRemove[1].resultPath == choices[2].resultPath)

        await session.removeSelection(nodeID: node.id, selectionIndex: 1)
        #expect(provider.selectionRequests.count == 3)
        #expect(provider.selectionRequests[2].count == 1)
        #expect(provider.selectionRequests[2][0].selectionIndex == 0)
        await session.removeSelection(nodeID: node.id, selectionIndex: 0)
        #expect(provider.selectionRequests.count == 3,
            "The last remaining selection cannot be removed.")
    }

    private func mapNode(planPath: String, planName: String,
                         selectedResultPath: String? = nil) -> MapResultChartActiveNode {
        let locator = CatalogTreeNodeLocator(rootName: "Layers", nodeType: "MultiResult",
            nodeName: planName, nodePath: [0], assetID: planPath,
            parentPlanAssetID: planPath, parentPlanNodePath: [0], parentPlanNodeName: planName)
        let choices = selectedResultPath.map {
            [sourceChoice(path: $0, name: "Selected Result")]
        } ?? []
        let slot = MapResultChartSelectionSlot(selectionIndex: 0, selectionMode: .latest,
            selectedResult: choices.first, choices: choices)
        return MapResultChartActiveNode(node: locator, nodeKind: "MultiResult", name: planName,
            selections: [slot], selectedMapType: nil, profileIndex: nil)
    }

    private func sourceChoice(path: String, name: String) -> MapResultChartSourceChoice {
        MapResultChartSourceChoice(resultPath: path, revision: "SOURCE-SHA",
            resultName: name, planName: nil, endTime: nil, isComputing: false)
    }

    private func liveEntry(projectSessionID: UUID, planPath: String, resultPath: String,
                           resultName: String, runID: String,
                           resultRevision: String?) -> WorkspaceResultComputeEntry {
        WorkspaceResultComputeEntry(runID: runID, projectSessionID: projectSessionID,
            editorID: UUID(), operationOwnerToken: "owner", operationContextID: "context",
            projectPath: "/fixture/Project.ras", projectRevision: "project-sha",
            projectXmlFingerprint: "xml-fingerprint", planPath: planPath,
            planRevision: "plan-sha", resultPath: resultPath, resultName: resultName,
            resultRevision: resultRevision, status: .running, fraction: 0.25,
            message: "Solving", taskName: "CPU solver", failureReason: nil)
    }
}
