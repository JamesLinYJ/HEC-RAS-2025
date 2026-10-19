import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct MapLinkedResultContextTests {
    private struct Fixture: Decodable {
        let project: String
        let anchor: String
        let candidatePlan: String
        let profileIndex: Int
        let mapType: String
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_LINKED_RESULT_MAP_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func bundledLinkServicesInstallOneSharedTimelineIntoTheOwningMapAndRestoreItsOriginalContext() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixtureDirectory = URL(fileURLWithPath: try #require(environment["HECRAS_LINKED_RESULT_MAP_ACCEPTANCE_DIRECTORY"]))
        let executable = URL(fileURLWithPath: try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        let workingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-linked-context-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: fixtureDirectory, to: workingRoot)
        defer { try? FileManager.default.removeItem(at: workingRoot) }

        let fixture = try JSONDecoder().decode(Fixture.self,
            from: Data(contentsOf: workingRoot.appendingPathComponent("LINKED_RESULT_MAP_FIXTURE.json")))
        let project = workingRoot.appendingPathComponent(fixture.project)
        let anchorURL = workingRoot.appendingPathComponent(fixture.anchor)
        var xml = try #require(String(data: Data(contentsOf: project), encoding: .utf8))
        if xml.first == "\u{FEFF}" { xml.removeFirst() }
        let sourceBytes = try LinkedContextSourceBytes(root: workingRoot)
        let revision = SHA256.hash(data: try Data(contentsOf: anchorURL))
            .map { String(format: "%02X", $0) }.joined()
        let client = BackendProcessClient(executableURL: executable)
        let context = try await BackendResultPlanContextProvider(client: client).inspect(
            resultPath: anchorURL, projectPath: project,
            projectXml: xml, revision: revision)
        let group = try #require(context.candidateGroups.first { $0.planName == fixture.candidatePlan })
        let mapID = UUID()
        let capture = try MapLinkedResultCapture(projectSessionID: UUID(), mapID: mapID,
            mapWorkflowIdentity: "fixture-map-workflow|\(mapID.uuidString)",
            projectPath: project, projectXML: xml,
            contextToken: "fixture-result-context", sourceIdentity: "fixture-source-slots",
            resultNodeIdentity: "fixture-result-node", selectionIndex: 0,
            anchorPath: context.resultPath, anchorRevision: context.revision)
        let selection = try MapLinkedResultSelectionBuilder.build(context: context,
            capture: capture, selectedGroupIDs: [group.id])

        let originalLocator = CatalogTreeNodeLocator(rootName: "Results", nodeType: "Result",
            nodeName: "Original Result", assetID: capture.anchorPath, mapType: "Plan")
        let originalIdentity = "\(mapID.uuidString)|\(originalLocator.sourceIdentity)"
        let originalRow = MapSourceRenderRecord(mapID: mapID, nodeID: "fixture-result-node",
            locator: originalLocator, familyOrder: 3, treeOrdinal: 0, activeLayerOrdinal: 0,
            contextIdentity: originalIdentity, payloadKind: "Result", payloadLayerIDs: [],
            isChecked: true, isEffectivelyVisible: true, isStatic: false,
            staticInsertionAfterRaster: false)
        let map = MapState(kind: .project, id: mapID, resultClient: client)
        map.installSourceMapRenderRows([originalRow])
        map.selectSourceContext(originalIdentity)
        let owner = LinkedMapTestOwner()
        let viewport = RasterMapViewExtent(minX: 0, minY: 0, maxX: 1, maxY: 1,
            pixelWidth: 32, pixelHeight: 32)

        let activated = try await map.activateLinkedResults(selection, capture: capture,
            projectXML: xml, viewport: viewport, ownerIsCurrent: {
                owner.isCurrent && map.id == capture.mapID
            })
        #expect(activated)

        // A map owner installs one synthetic composite render row; the .vis
        // Result row template remains available for the explicit return path.
        let compositeRows = map.sourceMapRenderRows
        #expect(compositeRows.count == 1)
        #expect(compositeRows.first?.payloadKind == "LinkedResult")
        #expect(compositeRows.first?.mapID == mapID)
        #expect(map.selectedSourceContextIdentity == map.linkedResults.sourceContextIdentity)

        await map.linkedResults.selectProfile(fixture.profileIndex, viewport: viewport)
        let profile = try #require(map.linkedResults.profileSnapshot)
        let frameIndices = profile.frames.compactMap(\.profileIndex)
        #expect(profile.frames.count == selection.results.count)
        #expect(Set(frameIndices).count > 1)
        #expect(profile.frames.allSatisfy { $0.unavailableReason == nil })
        let mapSnapshot = try #require(map.linkedResults.mapSnapshot)
        #expect(mapSnapshot.layers.count == selection.results.count)
        #expect(Set(mapSnapshot.layers.map(\.profileIndex)).count > 1)
        let canvasLayers = map.rasters([])
        #expect(canvasLayers.count == selection.results.count)
        let currentRows = map.sourceMapRenderRows
        #expect(currentRows.first?.contextIdentity == compositeRows.first?.contextIdentity)
        #expect(Set(currentRows.flatMap(\.payloadLayerIDs)) == Set(canvasLayers.map(\.id)))
        #expect(MapRenderComposition.rasterLayers(records: currentRows,
            candidates: canvasLayers, hiddenLayerIDs: []).count == selection.results.count)

        // A changed owner is rejected before another frame can replace the
        // accepted one; retirement restores the original .vis source row.
        owner.isCurrent = false
        await map.linkedResults.selectProfile(0, viewport: viewport)
        #expect(!map.linkedResults.isActive)
        #expect(map.sourceMapRenderRows.map(\.contextIdentity) == [originalIdentity])
        #expect(map.selectedSourceContextIdentity == originalIdentity)
        #expect(try sourceBytes.matches(root: workingRoot))
    }

    @Test @MainActor
    func mapCaptureRejectsAChangedProjectMapSourceOrSavedResultSlot() throws {
        let mapID = UUID()
        let projectURL = URL(fileURLWithPath: "/tmp/round30/project/Project.ras")
        let projectXML = "<Project/>"
        let resultPath = "/tmp/round30/project/anchor.hdf"
        let locator = CatalogTreeNodeLocator(rootName: "Results", nodeType: "Result",
            nodeName: "Anchor", assetID: resultPath)
        let capture = try MapLinkedResultCapture(projectSessionID: UUID(), mapID: mapID,
            mapWorkflowIdentity: "map-workflow-A", projectPath: projectURL,
            projectXML: projectXML, contextToken: "context-A", sourceIdentity: "source-A",
            resultNodeIdentity: locator.sourceIdentity, selectionIndex: 0,
            anchorPath: resultPath, anchorRevision: "ABCDEF")
        let choice = MapResultChartSourceChoice(resultPath: resultPath, revision: "ABCDEF",
            resultName: "Anchor", planName: "Plan A", endTime: nil, isComputing: false)
        let slot = MapResultChartSelectionSlot(selectionIndex: 0, selectionMode: .latest,
            selectedResult: choice, choices: [choice])
        let node = MapResultChartActiveNode(node: locator, nodeKind: "Result", name: "Anchor",
            selections: [slot], selectedMapType: "Depth", profileIndex: 0)
        let sources = MapResultChartSources(projectPath: projectURL.path,
            projectRevision: "PROJECT-REV", mapID: mapID.uuidString, mapIndex: 0,
            mapName: "Map", mapType: "Project", projectXmlSHA: capture.projectXMLSHA,
            visualizationRevision: "VIS-REV", contextToken: "context-A", activeNodes: [node])
        let mapRequest = MapResultChartMapRequest(projectPath: projectURL.path,
            projectXml: projectXML, projectXmlSHA: capture.projectXMLSHA,
            mapID: mapID.uuidString, mapIndex: 0, mapName: "Map", mapType: "Project",
            expectedVisualizationRevision: "VIS-REV")
        let snapshot = MapResultSourcesSnapshot(map: mapRequest, identity: "snapshot-A",
            sources: sources, selectionOverrides: [])
        let matched = capture.matches(projectSessionID: capture.projectSessionID,
            mapWorkflowIdentity: "map-workflow-A", projectPath: projectURL,
            projectXML: projectXML, sourceIdentity: "source-A", sources: snapshot)
        #expect(matched)
        #expect(!capture.matches(projectSessionID: capture.projectSessionID,
            mapWorkflowIdentity: "map-workflow-B", projectPath: projectURL,
            projectXML: projectXML, sourceIdentity: "source-A", sources: snapshot))
        #expect(!capture.matches(projectSessionID: capture.projectSessionID,
            mapWorkflowIdentity: "map-workflow-A", projectPath: projectURL,
            projectXML: projectXML, sourceIdentity: "source-B", sources: snapshot))
        #expect(!capture.matches(projectSessionID: UUID(),
            mapWorkflowIdentity: "map-workflow-A", projectPath: projectURL,
            projectXML: projectXML, sourceIdentity: "source-A", sources: snapshot))
        #expect(!capture.matches(projectSessionID: capture.projectSessionID,
            mapWorkflowIdentity: "map-workflow-A", projectPath: projectURL,
            projectXML: "<Project changed=\"true\"/>", sourceIdentity: "source-A", sources: snapshot))
        #expect(!capture.matches(projectSessionID: capture.projectSessionID,
            mapWorkflowIdentity: "map-workflow-A", projectPath: projectURL.appendingPathComponent("Other"),
            projectXML: projectXML, sourceIdentity: "source-A", sources: snapshot))
        let staleChoice = MapResultChartSourceChoice(resultPath: resultPath, revision: "STALE",
            resultName: "Anchor", planName: "Plan A", endTime: nil, isComputing: false)
        let staleSlot = MapResultChartSelectionSlot(selectionIndex: 0, selectionMode: .latest,
            selectedResult: staleChoice, choices: [staleChoice])
        let staleNode = MapResultChartActiveNode(node: locator, nodeKind: "Result", name: "Anchor",
            selections: [staleSlot], selectedMapType: "Depth", profileIndex: 0)
        let staleSources = MapResultChartSources(projectPath: projectURL.path,
            projectRevision: "PROJECT-REV", mapID: mapID.uuidString, mapIndex: 0,
            mapName: "Map", mapType: "Project", projectXmlSHA: capture.projectXMLSHA,
            visualizationRevision: "VIS-REV", contextToken: "context-A", activeNodes: [staleNode])
        let staleSnapshot = MapResultSourcesSnapshot(map: mapRequest, identity: "snapshot-B",
            sources: staleSources, selectionOverrides: [])
        #expect(!capture.matches(projectSessionID: capture.projectSessionID,
            mapWorkflowIdentity: "map-workflow-A", projectPath: projectURL,
            projectXML: projectXML, sourceIdentity: "source-A", sources: staleSnapshot))
    }
}

@MainActor private final class LinkedMapTestOwner {
    var isCurrent = true
}

private struct LinkedContextSourceBytes {
    private let values: [String: String]

    init(root: URL) throws {
        let prefix = SourceFilePaths.canonical(root) + "/"
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey]) else { throw CocoaError(.fileReadUnknown) }
        var result: [String: String] = [:]
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let path = SourceFilePaths.canonical(url)
            guard path.hasPrefix(prefix) else { throw CocoaError(.fileReadInvalidFileName) }
            let relative = String(path.dropFirst(prefix.count))
            result[relative] = SHA256.hash(data: try Data(contentsOf: url))
                .map { String(format: "%02X", $0) }.joined()
        }
        values = result
    }

    func matches(root: URL) throws -> Bool {
        values == (try LinkedContextSourceBytes(root: root).values)
    }
}
