import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Testing
import RASWorkspaceCore
@testable import HECRAS2025

struct BackendPlanComputeDuplexIntegrationTests {
    @Test @MainActor
    func bundledDuplexPlanComputeStreamsRealMapFramesAndCancelsAfterViewportRedraw() async throws {
        let environment = ProcessInfo.processInfo.environment
        let executablePath = try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let executable = URL(fileURLWithPath: executablePath)
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))
        let fixturePath = try #require(environment["HECRAS_PLAN_COMPUTE_ACCEPTANCE_DIRECTORY"])
        let fixture = URL(fileURLWithPath: fixturePath, isDirectory: true)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-compute-duplex-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        let projectURL = folder.appendingPathComponent("Plan Compute Acceptance.ras")
        let project = try ProjectDocument(contentsOf: projectURL)
        let plan = try #require(project.assets.first { $0.section == .plans && $0.name == "Plan Cancel" })
        // The exported map names the short plan. Bind its actual serialized
        // MultiResult to the existing long plan before loading source context.
        // No stored Result or profile payload is fabricated.
        let visualizationURL = projectURL.deletingPathExtension().appendingPathExtension("vis")
        let visualizationXML = try XMLDocument(contentsOf: visualizationURL,
            options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
        let resultGroups = try visualizationXML.nodes(forXPath:
            "//Maps/Map[@Name='Live compute map']/Tree/Nodes/Node[@Type='Root' and @Name='Results']/Node[@Type='MultiResult' and @Name='Plan CPU']")
        #expect(resultGroups.count == 1)
        let resultGroup = try #require(resultGroups.first as? XMLElement)
        let resultGroupName = try #require(resultGroup.attribute(forName: "Name"))
        resultGroupName.stringValue = plan.name
        try visualizationXML.xmlData(options: [.nodePreserveAll]).write(to: visualizationURL)
        let backendClient = BackendProcessClient(executableURL: executable)
        let modelProvider = BackendModelProvider(client: backendClient)
        modelProvider.setProject(project)
        let map = try Self.mapRequest(project: project)
        let mapProvider = BackendMapResultChartProvider(client: backendClient)
        let sources = try await mapProvider.loadSources(map: map, selectionOverrides: [])
        let node = try #require(sources.activeNodes.first {
            $0.nodeKind == "MultiResult" && Self.samePath($0.node.assetID, plan.url.path)
        })
        #expect(!sources.contextToken.isEmpty)
        #expect(node.selectedMapType == "Depth")

        let snapshot = try await modelProvider.load(plan, kind: .plan)
        let sourceRevision = try #require(snapshot.sourceRevision)
        let edits = EditorEdits(fields: [:], rows: [:], images: [:],
            sourceRevision: sourceRevision, sourceState: snapshot.sourceState)
        let inspection = try await modelProvider.inspectCompute(plan, edits: edits)
        #expect(inspection.canExecute && !inspection.requiresCUDA)

        let cancellation = try PlanComputeCancellationLease.create()
        defer { cancellation.cleanup() }
        let targetStream = AsyncStream<PlanComputeLiveMapTargetUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        targetStream.continuation.yield(.replace([]))
        let recorder = LiveDuplexMapFrameRecorder(map: map, node: node, contextToken: sources.contextToken,
            projectSessionID: UUID(), ownerToken: UUID().uuidString, operationContextID: UUID().uuidString,
            targets: targetStream.continuation)

        let result = try await modelProvider.executeComputeDuplex(plan, edits: edits,
            inspectionID: inspection.inspectionId, cancellation: cancellation.request,
            targetUpdates: targetStream.stream,
            update: { update in recorder.accept(update) })
        targetStream.continuation.finish()

        #expect(result.state == "cancelled")
        #expect(recorder.requestedCancellation)
        #expect(result.resultRevision != nil)
        #expect(result.resultPath.map { FileManager.default.fileExists(atPath: $0) } == true)
        let terminal = try #require(result.resultCompute)
        #expect(terminal.state == "cancelled")
        #expect(UUID(uuidString: terminal.runId) != nil)
        #expect(recorder.events.allSatisfy { $0.resultCompute?.runId == terminal.runId })
        #expect(recorder.firstTarget != nil && recorder.resizedTarget != nil)
        #expect(recorder.frames.count >= 2, "Live rendering diagnostics: \(recorder.events.compactMap(\.message).suffix(8).joined(separator: "; "))")
        let first = try #require(recorder.frames.first { $0.targetID == "duplex-first-viewport" })
        let resized = try #require(recorder.frames.last { $0.targetID == "duplex-resized-viewport" })
        #expect(first.width == 32 && first.height == 32)
        #expect(resized.width == 48 && resized.height == 24)
        #expect(first.runID == terminal.runId && resized.runID == terminal.runId)
        #expect(first.projectSessionID == recorder.projectSessionID.uuidString)
        #expect(resized.operationOwnerToken == recorder.ownerToken)
        #expect(resized.operationContextID == recorder.operationContextID)
        #expect(first.mapID == map.mapID && resized.mapID == map.mapID)
        #expect(first.profileIndex == 0 && resized.profileIndex == 0)
        #expect(first.profileName == resized.profileName && first.time == resized.time)
        #expect(first.rgba.count == first.width * first.height * 4)
        #expect(resized.rgba.count == resized.width * resized.height * 4)
        #expect(Self.hasVisiblePixel(resized.rgba))
        #expect(resized.targetSequence > first.targetSequence)
    }

    private static func mapRequest(project: ProjectDocument) throws -> MapResultChartMapRequest {
        let projectURL = try #require(project.url)
        // Match BackendModelProvider.saveRequest's actual current editor draft,
        // including its XML normalization, rather than a second raw-file view.
        let projectXML = project.editorXML
        let visualization = try VisualizationDocument(projectURL: projectURL)
        guard let sourceMap = visualization.maps.first else { throw CocoaError(.fileNoSuchFile) }
        let visualizationURL = projectURL.deletingPathExtension().appendingPathExtension("vis")
        return MapResultChartMapRequest(
            projectPath: SourceFilePaths.canonical(projectURL), projectXml: projectXML,
            projectXmlSHA: sha256(Data(projectXML.utf8)), mapID: UUID().uuidString,
            mapIndex: sourceMap.index, mapName: sourceMap.name, mapType: sourceMap.type,
            expectedVisualizationRevision: sha256(try Data(contentsOf: visualizationURL)))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    private static func hasVisiblePixel(_ rgba: Data) -> Bool {
        rgba.enumerated().contains { $0.offset % 4 == 3 && $0.element > 0 }
    }

    private static func samePath(_ left: String?, _ right: String) -> Bool {
        guard let left else { return false }
        return SourceFilePaths.canonical(URL(fileURLWithPath: left))
            == SourceFilePaths.canonical(URL(fileURLWithPath: right))
    }
}

@MainActor
private final class LiveDuplexMapFrameRecorder {
    let map: MapResultChartMapRequest
    let node: MapResultChartActiveNode
    let contextToken: String
    let projectSessionID: UUID
    let ownerToken: String
    let operationContextID: String
    private let targets: AsyncStream<PlanComputeLiveMapTargetUpdate>.Continuation
    private(set) var events: [BackendProgressUpdate] = []
    private(set) var frames: [PlanComputeLiveMapFrame] = []
    private(set) var firstTarget: PlanComputeLiveMapTarget?
    private(set) var resizedTarget: PlanComputeLiveMapTarget?
    private(set) var requestedCancellation = false

    init(map: MapResultChartMapRequest, node: MapResultChartActiveNode, contextToken: String,
         projectSessionID: UUID, ownerToken: String, operationContextID: String,
         targets: AsyncStream<PlanComputeLiveMapTargetUpdate>.Continuation) {
        self.map = map
        self.node = node
        self.contextToken = contextToken
        self.projectSessionID = projectSessionID
        self.ownerToken = ownerToken
        self.operationContextID = operationContextID
        self.targets = targets
    }

    func accept(_ update: PlanComputeDuplexUpdate) {
        events.append(update.progress)
        if firstTarget == nil,
           let identity = update.progress.resultCompute,
           identity.state == "running", identity.resultPath != nil,
           let profiles = update.progress.resultProfiles,
           profiles.errorMessage == nil,
           let profile = profiles.profiles.first(where: { $0.index == 0 }) {
            let target = makeTarget(identity: identity, profiles: profiles, profile: profile,
                targetID: "duplex-first-viewport", width: 32, height: 32)
            firstTarget = target
            targets.yield(.replace([target]))
        }

        guard let frame = update.liveMapFrame else { return }
        frames.append(frame)
        if frame.targetID == "duplex-first-viewport", resizedTarget == nil,
           let current = firstTarget {
            let resized = current.replacingViewport(targetID: "duplex-resized-viewport", width: 48, height: 24)
            resizedTarget = resized
            targets.yield(.replace([resized]))
        } else if frame.targetID == "duplex-resized-viewport", !requestedCancellation {
            requestedCancellation = true
            targets.yield(.cancel)
        }
    }

    private func makeTarget(identity: BackendResultComputeUpdate,
                            profiles: BackendResultProfilesUpdate,
                            profile: BackendResultProfile,
                            targetID: String, width: Int, height: Int) -> PlanComputeLiveMapTarget {
        PlanComputeLiveMapTarget(targetID: targetID, projectSessionID: projectSessionID.uuidString,
            operationOwnerToken: ownerToken, operationContextID: operationContextID,
            runID: identity.runId, projectPath: identity.projectPath,
            projectRevision: identity.projectRevision, projectXmlFingerprint: identity.projectXmlFingerprint,
            planPath: identity.planPath, planRevision: identity.planRevision, map: map,
            contextToken: contextToken, nodeID: node.id, node: node.node, selectionIndex: 0,
            selectionMode: "Latest", selectedResultPath: nil, profileIndex: profile.index,
            profileTime: profile.time, outputBlockName: profiles.outputBlockName,
            selectedMapType: node.selectedMapType ?? "Depth",
            viewport: RasterMapViewExtent(minX: 0, minY: 0, maxX: 32, maxY: 32,
                pixelWidth: width, pixelHeight: height))
    }
}

private extension PlanComputeLiveMapTarget {
    func replacingViewport(targetID: String, width: Int, height: Int) -> Self {
        .init(targetID: targetID, projectSessionID: projectSessionID,
            operationOwnerToken: operationOwnerToken, operationContextID: operationContextID,
            runID: runID, projectPath: projectPath, projectRevision: projectRevision,
            projectXmlFingerprint: projectXmlFingerprint, planPath: planPath, planRevision: planRevision,
            map: map, contextToken: contextToken, nodeID: nodeID, node: node,
            selectionIndex: selectionIndex, selectionMode: selectionMode,
            selectedResultPath: selectedResultPath, profileIndex: profileIndex,
            profileTime: profileTime, outputBlockName: outputBlockName,
            selectedMapType: selectedMapType,
            viewport: RasterMapViewExtent(minX: viewport.minX, minY: viewport.minY,
                maxX: viewport.maxX, maxY: viewport.maxY, pixelWidth: width, pixelHeight: height))
    }
}
