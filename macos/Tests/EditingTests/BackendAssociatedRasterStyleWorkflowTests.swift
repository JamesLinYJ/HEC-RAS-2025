import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendAssociatedRasterStyleWorkflowTests {
    @Test @MainActor
    func sharedGeometryRasterStyleUsesTheProductionStoreAndChangesRealPixelsAfterReopen() async throws {
        let fixture = try AssociatedStyleFixtureCopy()
        defer { fixture.remove() }
        let project = fixture.root.appendingPathComponent(fixture.manifest.associatedProjectRelativePath)
        var originalSources = try associatedStyleSources(in: fixture.root)
        let projectLockURL = project.deletingLastPathComponent().appendingPathComponent(".lock")
        let projectLockPath = SourceFilePaths.canonical(projectLockURL)
        #expect(originalSources[projectLockPath] == nil)
        let store = WorkspaceStore(system: AssociatedStyleFixtureServices(),
            modelProvider: BackendModelProvider(client: fixture.client))
        try await associatedStyleOpen(store, project: project)
        let expectedLockBytes = Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
        #expect(try Data(contentsOf: projectLockURL) == expectedLockBytes)
        originalSources[projectLockPath] = expectedLockBytes
        #expect(try associatedStyleSources(in: fixture.root) == originalSources,
            "Opening the project may add only its documented process lock file.")
        let map = try #require(store.mapDocuments.first {
            $0.kind == .geometry && $0.name == fixture.manifest.associatedMapName
        })
        await store.configureMapResultSources(map.id)
        var nodes = try await store.sourceMapLayerNodes(map.id)
        let sourceNode = try #require(nodes.first {
            $0.sourceLocator?.rootName == "Matching Layers"
                && $0.sourceLocator?.associationKind == "NValue"
        })
        #expect(await store.setSourceMapVisibility(sourceNode, checked: true, mapID: map.id))
        nodes = try await store.sourceMapLayerNodes(map.id)
        let currentNode = try #require(nodes.first { $0.id == sourceNode.id })
        let style = try await store.makeAssociatedRasterStyleSession(node: currentNode, mapID: map.id)
        await style.load()
        let initialContext = try #require(style.context)
        let initialSnapshot = try #require(style.snapshot)
        #expect(style.errorMessage == nil)
        #expect(initialContext.geometryNodes.count == 2)
        #expect(initialContext.planNodes.isEmpty && initialContext.resultOwner == nil)
        #expect(initialSnapshot.node == currentNode.sourceLocator)
        #expect(initialSnapshot.geometryNodes == initialContext.geometryNodes)
        let beforePixels = try await associatedStylePixels(context: initialContext, client: fixture.client)
        let visualization = project.deletingPathExtension().appendingPathExtension("vis")
        let beforeVisualBytes = try Data(contentsOf: visualization)

        var draft = try #require(style.draft)
        let appliedAlpha = draft.alpha == 211 ? 212 : 211
        draft.alpha = appliedAlpha
        draft.paletteID = nil
        draft.name = "Stored native NValue style"
        draft.valueSource = "Manual"
        draft.isEditing = true
        draft.isSurfaceFillEnabled = true
        for index in draft.stops.indices { draft.stops[index].color = "#FF3366AA" }
        style.draft = draft
        #expect(await style.apply())
        #expect(style.errorMessage == nil && !style.isApplying)
        let acceptedContext = try #require(style.context)
        let acceptedSnapshot = try #require(style.snapshot)
        #expect(acceptedContext.node == initialContext.node)
        #expect(acceptedContext.geometryNodes == initialContext.geometryNodes)
        #expect(acceptedContext.sourcePath == initialContext.sourcePath)
        #expect(acceptedContext.sourceRevision == initialContext.sourceRevision)
        #expect(acceptedContext.map.expectedVisualizationRevision != initialContext.map.expectedVisualizationRevision)
        #expect(acceptedSnapshot.draft.alpha == appliedAlpha)
        #expect(acceptedSnapshot.draft.stops.allSatisfy { $0.color == "#FF3366AA" })
        #expect(try Data(contentsOf: visualization) != beforeVisualBytes)
        let afterPixels = try await associatedStylePixels(context: acceptedContext, client: fixture.client)
        #expect(!beforePixels.isEmpty && beforePixels != afterPixels)
        #expect(try associatedStyleSources(in: fixture.root) == originalSources)

        store.requestClose()
        if store.showDiscardConfirmation { store.discardAndContinue() }
        try #require(store.document == nil)

        let reopened = WorkspaceStore(system: AssociatedStyleFixtureServices(),
            modelProvider: BackendModelProvider(client: fixture.client))
        try await associatedStyleOpen(reopened, project: project)
        let reopenedMap = try #require(reopened.mapDocuments.first {
            $0.kind == .geometry && $0.name == map.name
        })
        await reopened.configureMapResultSources(reopenedMap.id)
        let reopenedNodes = try await reopened.sourceMapLayerNodes(reopenedMap.id)
        let reopenedNode = try #require(reopenedNodes.first {
            $0.sourceLocator == initialContext.node
        })
        let reopenedStyle = try await reopened.makeAssociatedRasterStyleSession(node: reopenedNode, mapID: reopenedMap.id)
        await reopenedStyle.load()
        let reopenedSnapshot = try #require(reopenedStyle.snapshot)
        #expect(reopenedStyle.errorMessage == nil)
        #expect(reopenedSnapshot.draft.alpha == appliedAlpha)
        #expect(reopenedSnapshot.draft.stops.map(\.color) == acceptedSnapshot.draft.stops.map(\.color))
        #expect(reopenedSnapshot.draft.stops.map(\.value) == acceptedSnapshot.draft.stops.map(\.value))
        let reopenedContext = try #require(reopenedStyle.context)
        #expect(try await associatedStylePixels(context: reopenedContext, client: fixture.client) == afterPixels)
        #expect(try associatedStyleSources(in: fixture.root) == originalSources)
        reopened.requestClose()
        if reopened.showDiscardConfirmation { reopened.discardAndContinue() }
        try #require(reopened.document == nil)
    }

    @Test @MainActor
    func planAndResultChildRasterStylesKeepExactOwnersAcrossWritesAndRejectStaleSessions() async throws {
        let fixture = try AssociatedStyleFixtureCopy()
        defer { fixture.remove() }
        let project = fixture.root.appendingPathComponent(fixture.manifest.cpuProjectRelativePath)
        let plan = fixture.root.appendingPathComponent(fixture.manifest.cpuPlanRelativePath)
        var originalSources = try associatedStyleSources(in: fixture.root)
        let projectLockURL = project.deletingLastPathComponent().appendingPathComponent(".lock")
        let projectLockPath = SourceFilePaths.canonical(projectLockURL)
        #expect(originalSources[projectLockPath] == nil)
        let store = WorkspaceStore(system: AssociatedStyleFixtureServices(),
            modelProvider: BackendModelProvider(client: fixture.client))
        try await associatedStyleOpen(store, project: project)
        let expectedLockBytes = Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
        #expect(try Data(contentsOf: projectLockURL) == expectedLockBytes)
        originalSources[projectLockPath] = expectedLockBytes
        #expect(try associatedStyleSources(in: fixture.root) == originalSources,
            "Opening the project may add only its documented process lock file.")
        let planAsset = try #require(store.assets.first {
            $0.section == .plans && $0.isModelFile
                && SourceFilePaths.canonical($0.url) == SourceFilePaths.canonical(plan)
        })
        let existingMapIDs = Set(store.mapDocuments.map(\.id))
        #expect(await store.focusPlanInNewMap(assetID: planAsset.id))
        let map = try #require(store.mapDocuments.first {
            $0.kind == .plan && !existingMapIDs.contains($0.id)
        })
        await store.configureMapResultSources(map.id)
        var nodes = try await store.sourceMapLayerNodes(map.id)
        let planTerrain = try #require(nodes.first {
            $0.sourceLocator?.associationKind == "Terrain"
                && $0.sourceLocator?.parentPlanAssetID.map {
                    SourceFilePaths.canonical(URL(fileURLWithPath: $0))
                } == SourceFilePaths.canonical(plan)
                && $0.sourceLocator?.parentResultNodeType == nil
        })
        let planStyle = try await store.makeAssociatedRasterStyleSession(node: planTerrain, mapID: map.id)
        await planStyle.load()
        let planContext = try #require(planStyle.context)
        #expect(planStyle.snapshot != nil && planStyle.errorMessage == nil)
        #expect(planContext.planNodes.count == 1 && planContext.resultOwner == nil)
        var planDraft = try #require(planStyle.draft)
        planDraft.alpha = 177
        planStyle.draft = planDraft
        #expect(await planStyle.apply())
        #expect(planStyle.snapshot?.draft.alpha == 177)

        let resultAsset = try #require(store.assets.first { $0.section == .results })
        await store.addAssetsToMap([resultAsset], mapID: map.id)
        await store.configureMapResultSources(map.id)
        nodes = try await store.sourceMapLayerNodes(map.id)
        let resultTerrain = try #require(nodes.first {
            $0.sourceLocator?.associationKind == "Terrain"
                && $0.sourceLocator?.parentResultNodeType == "MultiResult"
        })
        let resultStyle = try await store.makeAssociatedRasterStyleSession(node: resultTerrain, mapID: map.id)
        await resultStyle.load()
        let resultContext = try #require(resultStyle.context)
        let resultSnapshot = try #require(resultStyle.snapshot)
        let owner = try #require(resultContext.resultOwner)
        #expect(resultStyle.errorMessage == nil)
        #expect(owner.selectionIndex == 0)
        #expect(resultSnapshot.resultOwner?.resultNode == owner.resultNode)
        #expect(resultSnapshot.resultOwner?.selectedResultPath == owner.selectedResultPath)
        #expect(resultSnapshot.resultOwner?.selectedResultRevision == owner.selectedResultRevision)
        #expect(resultContext.node.parentResultAssetID == owner.selectedResultPath)
        #expect(resultContext.node != planContext.node)
        var resultDraft = try #require(resultStyle.draft)
        resultDraft.alpha = 133
        resultStyle.draft = resultDraft
        #expect(await resultStyle.apply())
        #expect(resultStyle.snapshot?.draft.alpha == 133)
        #expect(resultStyle.context?.resultOwner?.selectedResultPath == owner.selectedResultPath)
        #expect(resultStyle.context?.resultOwner?.selectedResultRevision == owner.selectedResultRevision)

        let visualization = project.deletingPathExtension().appendingPathExtension("vis")
        let savedVisualBytes = try Data(contentsOf: visualization)
        // This editor predates Result insertion and the subsequent style write.
        // It must not publish against the old map's captured visualization SHA.
        #expect(await planStyle.apply() == false)
        #expect(planStyle.errorMessage != nil)
        #expect(try Data(contentsOf: visualization) == savedVisualBytes)

        store.requestClose()
        if store.showDiscardConfirmation { store.discardAndContinue() }
        try #require(store.document == nil)

        let reopened = WorkspaceStore(system: AssociatedStyleFixtureServices(),
            modelProvider: BackendModelProvider(client: fixture.client))
        try await associatedStyleOpen(reopened, project: project)
        let reopenedMap = try #require(reopened.mapDocuments.first {
            $0.kind == .plan && $0.name == map.name
        })
        await reopened.configureMapResultSources(reopenedMap.id)
        let reopenedNodes = try await reopened.sourceMapLayerNodes(reopenedMap.id)
        let reopenedPlanTerrain = try #require(reopenedNodes.first {
            $0.sourceLocator?.associationKind == "Terrain"
                && $0.sourceLocator?.parentPlanAssetID.map {
                    SourceFilePaths.canonical(URL(fileURLWithPath: $0))
                } == SourceFilePaths.canonical(plan)
                && $0.sourceLocator?.parentResultNodeType == nil
        })
        let reopenedResultTerrain = try #require(reopenedNodes.first {
            $0.sourceLocator?.associationKind == "Terrain"
                && $0.sourceLocator?.parentResultNodeType == "MultiResult"
        })
        let reopenedPlanStyle = try await reopened.makeAssociatedRasterStyleSession(node: reopenedPlanTerrain, mapID: reopenedMap.id)
        await reopenedPlanStyle.load()
        #expect(reopenedPlanStyle.snapshot?.draft.alpha == 177)
        let reopenedResultStyle = try await reopened.makeAssociatedRasterStyleSession(node: reopenedResultTerrain, mapID: reopenedMap.id)
        await reopenedResultStyle.load()
        #expect(reopenedResultStyle.snapshot?.draft.alpha == 133)
        #expect(reopenedResultStyle.context?.resultOwner?.selectionIndex == 0)
        #expect(try associatedStyleSources(in: fixture.root) == originalSources)
        reopened.requestClose()
        if reopened.showDiscardConfirmation { reopened.discardAndContinue() }
        try #require(reopened.document == nil)
    }
}

private struct AssociatedStyleFixtureManifest: Decodable {
    let associatedProjectRelativePath: String
    let associatedMapName: String
    let cpuProjectRelativePath: String
    let cpuPlanRelativePath: String
}

private struct AssociatedStyleFixtureCopy {
    let root: URL
    let manifest: AssociatedStyleFixtureManifest
    let client: BackendProcessClient

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: try #require(environment["HECRAS_ASSOCIATED_STYLE_ACCEPTANCE_DIRECTORY"]))
        client = BackendProcessClient(executableURL: URL(fileURLWithPath:
            try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"])))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("associated-style-" + UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: root)
        do {
            manifest = try JSONDecoder().decode(AssociatedStyleFixtureManifest.self,
                from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private func associatedStylePixels(context: AssociatedRasterStyleContext,
                                   client: BackendProcessClient) async throws -> Data {
    let mapID = try #require(UUID(uuidString: context.map.mapID))
    let owners = context.resultOwner.map { [$0] } ?? []
    let capture = try AssociatedMapLayerCapture(projectSessionID: context.projectSessionID,
        mapID: mapID, mapWorkflowIdentity: context.mapWorkflowIdentity,
        map: context.map, geometryNodes: context.geometryNodes,
        planNodes: context.planNodes, resultOwners: owners,
        associationNode: context.node, assetPath: context.sourcePath,
        isChecked: true, effectiveVisible: true)
    let request = AssociatedMapLayersRequest(map: context.map,
        geometryNodes: context.geometryNodes, planNodes: context.planNodes,
        resultOwners: owners, associationNodes: [context.node],
        viewport: .init(minX: 0, minY: 0, maxX: 16, maxY: 16),
        width: 32, height: 24, contextToken: nil)
    let response = try await BackendAssociatedMapLayerProvider(client: client)
        .load(request, captures: [capture])
    try #require(response.layers.count == 1)
    let layer = try #require(response.layers.first)
    #expect(layer.status == .available)
    return layer.rgba
}

@MainActor
private func associatedStyleOpen(_ store: WorkspaceStore, project: URL) async throws {
    store.requestOpen(project)
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while ContinuousClock.now < deadline {
        if store.document?.url?.standardizedFileURL == project.standardizedFileURL && !store.isOpeningProject { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw AssociatedStyleFixtureError.projectOpenTimedOut
}

private func associatedStyleSources(in root: URL) throws -> [String: Data] {
    guard let enumerator = FileManager.default.enumerator(at: root,
        includingPropertiesForKeys: [.isRegularFileKey]) else { throw AssociatedStyleFixtureError.unreadableFixture }
    var result: [String: Data] = [:]
    for case let file as URL in enumerator {
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        // .vis is intentionally excluded: it is the sole style save boundary.
        if file.pathExtension.lowercased() != "vis" {
            result[file.path] = try Data(contentsOf: file)
        }
    }
    return result
}

@MainActor
private final class AssociatedStyleFixtureServices: WorkspaceSystemServices {
    func chooseProject() -> URL? { nil }
    func chooseProjectDestination(name: String) -> URL? { nil }
    func chooseFolder(title: String) -> URL? { nil }
    func chooseVectorLayer() -> URL? { nil }
    func chooseConnectionFile() -> URL? { nil }
    func chooseInputFiles() -> [URL] { [] }
    func chooseImageFiles() -> [URL] { [] }
    func chooseProjectionFile() -> URL? { nil }
    func reveal(_ url: URL) {}
    func copy(_ text: String) {}
    func openWebsite(_ url: URL) {}
}

private enum AssociatedStyleFixtureError: Error {
    case projectOpenTimedOut
    case unreadableFixture
}
