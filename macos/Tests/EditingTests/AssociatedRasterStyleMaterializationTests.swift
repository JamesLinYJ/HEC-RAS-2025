import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct AssociatedRasterStyleMaterializationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_ASSOCIATED_STYLE_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func implicitAssociationApplyMaterializesOnceAndKeepsTheSameSessionEditable() async throws {
        let fixture = try MaterializationStyleFixture()
        defer { fixture.remove() }
        let project = fixture.root.appendingPathComponent(fixture.manifest.associatedProjectRelativePath)
        let visualization = project.deletingPathExtension().appendingPathExtension("vis")
        #expect(try materializationRemoveAssociationRow(visualization,
            mapName: fixture.manifest.associatedMapName,
            nodeType: "Terrain", nodeName: fixture.manifest.associatedTerrainName))
        let sparseVisualizationBytes = try Data(contentsOf: visualization)
        var otherFileBytes = try materializationFiles(in: fixture.root, excluding: visualization)
        let projectLockURL = project.deletingLastPathComponent().appendingPathComponent(".lock")
        let projectLockPath = SourceFilePaths.canonical(projectLockURL)
        #expect(otherFileBytes[projectLockPath] == nil)

        let store = WorkspaceStore(system: MaterializationStyleServices(),
            modelProvider: BackendModelProvider(client: fixture.client))
        try await materializationOpen(store, project: project)
        let expectedLockBytes = Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
        #expect(try Data(contentsOf: projectLockURL) == expectedLockBytes)
        otherFileBytes[projectLockPath] = expectedLockBytes
        #expect(try materializationFiles(in: fixture.root, excluding: visualization) == otherFileBytes,
            "Opening the project may add only its documented process lock file.")
        let map = try #require(store.mapDocuments.first {
            $0.kind == .geometry && $0.name == fixture.manifest.associatedMapName
        })
        await store.configureMapResultSources(map.id)
        let rows = try await store.sourceMapLayerRows(map.id)
        let row = try #require(rows.first {
            $0.node.sourceLocator?.rootName == "Matching Layers"
                && $0.node.sourceLocator?.associationKind == "Terrain"
                && $0.node.name == fixture.manifest.associatedTerrainName
        })
        #expect(row.node.sourceLocator?.nodePath == nil,
            "The test starts from a genuine source default that is absent from the sparse .vis tree.")

        let style = try await store.makeAssociatedRasterStyleSession(node: row.node, mapID: map.id)
        await style.load()
        let implicitContext = try #require(style.context)
        #expect(implicitContext.node.nodePath == nil)
        #expect(style.snapshot?.node == implicitContext.node)
        #expect(try Data(contentsOf: visualization) == sparseVisualizationBytes,
            "Opening a style editor must not materialize or write the implicit row.")

        var firstDraft = try #require(style.draft)
        firstDraft.alpha = firstDraft.alpha == 214 ? 213 : 214
        style.draft = firstDraft
        #expect(await style.apply(), "The real Host Apply receipt should migrate the implicit row.")
        let firstPersistedContext = try #require(style.context)
        #expect(firstPersistedContext.node.nodePath?.isEmpty == false)
        #expect(firstPersistedContext.node.rootName == implicitContext.node.rootName)
        #expect(firstPersistedContext.node.nodeType == implicitContext.node.nodeType)
        #expect(firstPersistedContext.node.nodeName == implicitContext.node.nodeName)
        #expect(firstPersistedContext.node.parentGeometryAssetID == implicitContext.node.parentGeometryAssetID)
        #expect(firstPersistedContext.node.parentGeometryNodePath == implicitContext.node.parentGeometryNodePath)
        #expect(firstPersistedContext.node.parentPlanAssetID == implicitContext.node.parentPlanAssetID)
        #expect(firstPersistedContext.node.associationAssetID == implicitContext.node.associationAssetID)
        #expect(firstPersistedContext.sourcePath == implicitContext.sourcePath)
        #expect(firstPersistedContext.sourceRevision == implicitContext.sourceRevision)
        #expect(firstPersistedContext.map.expectedVisualizationRevision != implicitContext.map.expectedVisualizationRevision)
        #expect(style.errorMessage == nil && style.snapshot?.draft.alpha == firstDraft.alpha)
        let firstApplyBytes = try Data(contentsOf: visualization)
        #expect(firstApplyBytes != sparseVisualizationBytes)
        #expect(try materializationFiles(in: fixture.root, excluding: visualization) == otherFileBytes,
            "The accepted style write may change only the target visualization file.")

        var secondDraft = try #require(style.draft)
        secondDraft.alpha = secondDraft.alpha == 199 ? 198 : 199
        style.draft = secondDraft
        #expect(await style.apply(), "The same session must remain usable after path materialization.")
        let secondPersistedContext = try #require(style.context)
        #expect(secondPersistedContext.node == firstPersistedContext.node)
        #expect(style.errorMessage == nil && style.snapshot?.draft.alpha == secondDraft.alpha)
        #expect(try Data(contentsOf: visualization) != firstApplyBytes)
        #expect(try materializationFiles(in: fixture.root, excluding: visualization) == otherFileBytes)
        store.requestClose()
        if store.showDiscardConfirmation { store.discardAndContinue() }
        try #require(store.document == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_ASSOCIATED_STYLE_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func resultOwnedImplicitGeometryAndRasterMaterializeAndRemainEditableAfterReopen() async throws {
        let fixture = try MaterializationStyleFixture()
        defer { fixture.remove() }
        let project = fixture.root.appendingPathComponent(fixture.manifest.cpuProjectRelativePath)
        let visualization = project.deletingPathExtension().appendingPathExtension("vis")
        let resultURL = fixture.root.appendingPathComponent(fixture.manifest.cpuResultRelativePath)
        var sourceFilesBefore = try materializationFiles(in: fixture.root, excluding: visualization)
        let projectLockURL = project.deletingLastPathComponent().appendingPathComponent(".lock")
        let projectLockPath = SourceFilePaths.canonical(projectLockURL)
        #expect(sourceFilesBefore[projectLockPath] == nil)

        let store = WorkspaceStore(system: MaterializationStyleServices(),
            modelProvider: BackendModelProvider(client: fixture.client))
        try await materializationOpen(store, project: project)
        let expectedLockBytes = Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
        #expect(try Data(contentsOf: projectLockURL) == expectedLockBytes)
        sourceFilesBefore[projectLockPath] = expectedLockBytes
        #expect(try materializationFiles(in: fixture.root, excluding: visualization) == sourceFilesBefore,
            "Opening the project may add only its documented process lock file.")
        let map = try #require(store.mapDocuments.first {
            $0.kind == .geometry && $0.name == fixture.manifest.cpuMapName
        })
        await store.configureMapResultSources(map.id)
        try await materializationSelectResult(store, mapID: map.id,
            planName: fixture.manifest.cpuPlanName, resultURL: resultURL,
            revision: fixture.manifest.cpuResultRevision)
        let rows = try await store.sourceMapLayerRows(map.id)
        let terrainRow = try #require(rows.first {
            $0.node.sourceLocator?.nodeType == "Terrain"
                && $0.node.sourceLocator?.parentResultNodeType == "MultiResult"
                && $0.node.sourceLocator?.parentResultNodeName == fixture.manifest.cpuPlanName
        })
        let implicitLocator = try #require(terrainRow.node.sourceLocator)
        #expect(implicitLocator.nodePath == nil)
        #expect(implicitLocator.parentGeometryNodePath == nil,
            "The selected Result tree starts with both its embedded Geometry and Terrain row implicit.")
        let parentResultAssetID = try #require(implicitLocator.parentResultAssetID)
        #expect(SourceFilePaths.canonical(URL(fileURLWithPath: parentResultAssetID))
            == SourceFilePaths.canonical(resultURL))
        #expect(implicitLocator.parentResultRevision?.caseInsensitiveCompare(
            fixture.manifest.cpuResultRevision) == .orderedSame)

        let sparseVisualizationBytes = try Data(contentsOf: visualization)
        let style = try await store.makeAssociatedRasterStyleSession(node: terrainRow.node, mapID: map.id)
        await style.load()
        let originalContext = try #require(style.context)
        let originalSnapshot = try #require(style.snapshot)
        let resultOwner = try #require(originalContext.resultOwner)
        #expect(style.errorMessage == nil)
        #expect(originalSnapshot.node == implicitLocator)
        #expect(resultOwner.resultNode.nodeType == implicitLocator.parentResultNodeType)
        #expect(resultOwner.resultNode.nodePath == implicitLocator.parentResultNodePath)
        #expect(SourceFilePaths.canonical(URL(fileURLWithPath: resultOwner.selectedResultPath))
            == SourceFilePaths.canonical(resultURL))
        #expect(resultOwner.selectedResultRevision.caseInsensitiveCompare(
            fixture.manifest.cpuResultRevision) == .orderedSame)
        #expect(try Data(contentsOf: visualization) == sparseVisualizationBytes,
            "Opening the implicit Result-owned style must not materialize its source tree.")

        var firstDraft = try #require(style.draft)
        firstDraft.alpha = firstDraft.alpha == 204 ? 203 : 204
        style.draft = firstDraft
        #expect(await style.apply(),
            "A successful Host receipt may persist only the leaf path and its exact embedded Geometry parent path.")
        let firstContext = try #require(style.context)
        let firstLocator = firstContext.node
        var normalizedLocator = firstLocator
        normalizedLocator.nodePath = nil
        normalizedLocator.parentGeometryNodePath = nil
        #expect(normalizedLocator == implicitLocator,
            "The materialization receipt must preserve every locator field except the two source-authorized paths.")
        #expect(firstLocator.nodePath?.isEmpty == false)
        #expect(firstLocator.parentGeometryNodePath?.isEmpty == false)
        #expect(firstLocator.parentResultNodeType == implicitLocator.parentResultNodeType)
        #expect(firstLocator.parentResultNodePath == implicitLocator.parentResultNodePath)
        #expect(firstLocator.parentResultNodeName == implicitLocator.parentResultNodeName)
        #expect(firstLocator.parentResultAssetID == implicitLocator.parentResultAssetID)
        #expect(firstLocator.parentResultRevision == implicitLocator.parentResultRevision)
        #expect(firstLocator.parentGeometryAssetID == implicitLocator.parentGeometryAssetID)
        #expect(firstLocator.parentGeometryNodeName == implicitLocator.parentGeometryNodeName)
        #expect(firstLocator.parentPlanAssetID == implicitLocator.parentPlanAssetID)
        #expect(firstLocator.parentPlanNodePath == implicitLocator.parentPlanNodePath)
        #expect(firstLocator.parentPlanNodeName == implicitLocator.parentPlanNodeName)
        #expect(firstLocator.associationAssetID == implicitLocator.associationAssetID)
        #expect(firstLocator.associationKind == implicitLocator.associationKind)
        let geometryPath = try #require(firstLocator.parentGeometryNodePath)
        let resultPath = try #require(firstLocator.parentResultNodePath)
        let leafPath = try #require(firstLocator.nodePath)
        #expect(geometryPath.count == resultPath.count + 1)
        #expect(Array(geometryPath.prefix(resultPath.count)) == resultPath)
        #expect(leafPath.count == geometryPath.count + 1)
        #expect(Array(leafPath.prefix(geometryPath.count)) == geometryPath)
        #expect(firstContext.resultOwner?.resultNode == resultOwner.resultNode)
        #expect(firstContext.resultOwner?.selectedResultPath == resultOwner.selectedResultPath)
        #expect(firstContext.resultOwner?.selectedResultRevision == resultOwner.selectedResultRevision)
        #expect(firstContext.map.expectedVisualizationRevision != originalContext.map.expectedVisualizationRevision)
        #expect(style.errorMessage == nil && style.snapshot?.draft.alpha == firstDraft.alpha)
        let firstVisualizationBytes = try Data(contentsOf: visualization)
        #expect(firstVisualizationBytes != sparseVisualizationBytes)
        #expect(try materializationFiles(in: fixture.root, excluding: visualization) == sourceFilesBefore,
            "Materializing the style row must leave the embedded Result and source rasters unchanged.")

        var secondDraft = try #require(style.draft)
        secondDraft.alpha = secondDraft.alpha == 197 ? 196 : 197
        style.draft = secondDraft
        #expect(await style.apply(), "The receipt-migrated Result row remains editable in the same session.")
        let secondContext = try #require(style.context)
        #expect(secondContext.node == firstLocator)
        #expect(secondContext.resultOwner?.resultNode == resultOwner.resultNode)
        #expect(secondContext.resultOwner?.selectedResultPath == resultOwner.selectedResultPath)
        #expect(secondContext.resultOwner?.selectedResultRevision == resultOwner.selectedResultRevision)
        #expect(style.errorMessage == nil && style.snapshot?.draft.alpha == secondDraft.alpha)
        #expect(try Data(contentsOf: visualization) != firstVisualizationBytes)
        #expect(try materializationFiles(in: fixture.root, excluding: visualization) == sourceFilesBefore)

        store.requestClose()
        if store.showDiscardConfirmation { store.discardAndContinue() }
        try #require(store.document == nil)

        let reopened = WorkspaceStore(system: MaterializationStyleServices(),
            modelProvider: BackendModelProvider(client: fixture.client))
        try await materializationOpen(reopened, project: project)
        let reopenedMap = try #require(reopened.mapDocuments.first {
            $0.kind == .geometry && $0.name == fixture.manifest.cpuMapName
        })
        await reopened.configureMapResultSources(reopenedMap.id)
        try await materializationSelectResult(reopened, mapID: reopenedMap.id,
            planName: fixture.manifest.cpuPlanName, resultURL: resultURL,
            revision: fixture.manifest.cpuResultRevision)
        let reopenedRows = try await reopened.sourceMapLayerRows(reopenedMap.id)
        let reopenedTerrain = try #require(reopenedRows.first {
            $0.node.sourceLocator == secondContext.node
        })
        let reopenedStyle = try await reopened.makeAssociatedRasterStyleSession(
            node: reopenedTerrain.node, mapID: reopenedMap.id)
        await reopenedStyle.load()
        #expect(reopenedStyle.errorMessage == nil)
        #expect(reopenedStyle.snapshot?.draft.alpha == secondDraft.alpha)
        #expect(reopenedStyle.context?.resultOwner?.selectedResultPath == resultOwner.selectedResultPath)
        #expect(reopenedStyle.context?.resultOwner?.selectedResultRevision == resultOwner.selectedResultRevision)

        let resultBytes = try Data(contentsOf: resultURL)
        var changedResultBytes = resultBytes
        changedResultBytes.append(0x00)
        try changedResultBytes.write(to: resultURL, options: .atomic)
        var staleSourceDraft = try #require(reopenedStyle.draft)
        staleSourceDraft.alpha = staleSourceDraft.alpha == 190 ? 189 : 190
        reopenedStyle.draft = staleSourceDraft
        let beforeRejectedResultWrite = try Data(contentsOf: visualization)
        #expect(await reopenedStyle.apply() == false)
        #expect(reopenedStyle.errorMessage != nil)
        #expect(try Data(contentsOf: visualization) == beforeRejectedResultWrite,
            "A changed selected Result HDF must reject the style write without changing .vis.")

        // Restore the copied fixture HDF before exercising the independent
        // visualization guard. The open style context still has the old .vis
        // revision, so an external edit must also be rejected.
        try resultBytes.write(to: resultURL, options: .atomic)
        var changedVisualizationBytes = beforeRejectedResultWrite
        changedVisualizationBytes.append(0x20)
        try changedVisualizationBytes.write(to: visualization, options: .atomic)
        var staleVisualizationDraft = try #require(reopenedStyle.draft)
        staleVisualizationDraft.alpha = staleVisualizationDraft.alpha == 188 ? 187 : 188
        reopenedStyle.draft = staleVisualizationDraft
        #expect(await reopenedStyle.apply() == false)
        #expect(reopenedStyle.errorMessage != nil)
        #expect(try Data(contentsOf: visualization) == changedVisualizationBytes,
            "An external visualization edit must not be overwritten by a stale Result-owned editor.")
        #expect(try materializationFiles(in: fixture.root, excluding: visualization) == sourceFilesBefore)
        reopened.requestClose()
        if reopened.showDiscardConfirmation { reopened.discardAndContinue() }
        try #require(reopened.document == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_ASSOCIATED_STYLE_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func rasterStyleStillRejectsExternalVisualizationAndSourceChanges() async throws {
        let visualizationFixture = try MaterializationStyleFixture()
        defer { visualizationFixture.remove() }
        let visualizationProject = visualizationFixture.root
            .appendingPathComponent(visualizationFixture.manifest.associatedProjectRelativePath)
        let visualizationURL = visualizationProject.deletingPathExtension().appendingPathExtension("vis")
        let visualizationStore = WorkspaceStore(system: MaterializationStyleServices(),
            modelProvider: BackendModelProvider(client: visualizationFixture.client))
        try await materializationOpen(visualizationStore, project: visualizationProject)
        let visualizationMap = try #require(visualizationStore.mapDocuments.first {
            $0.kind == .geometry && $0.name == visualizationFixture.manifest.associatedMapName
        })
        await visualizationStore.configureMapResultSources(visualizationMap.id)
        let visualizationRows = try await visualizationStore.sourceMapLayerRows(visualizationMap.id)
        let visualizationRow = try #require(visualizationRows.first {
            $0.node.sourceLocator?.associationKind == "Terrain"
                && $0.node.name == visualizationFixture.manifest.associatedTerrainName
        })
        let visualizationStyle = try await visualizationStore.makeAssociatedRasterStyleSession(
            node: visualizationRow.node, mapID: visualizationMap.id)
        await visualizationStyle.load()
        var externalVisualizationBytes = try Data(contentsOf: visualizationURL)
        externalVisualizationBytes.append(0x20)
        try externalVisualizationBytes.write(to: visualizationURL, options: .atomic)
        var visualizationDraft = try #require(visualizationStyle.draft)
        visualizationDraft.alpha = visualizationDraft.alpha == 181 ? 180 : 181
        visualizationStyle.draft = visualizationDraft
        #expect(await visualizationStyle.apply() == false)
        #expect(visualizationStyle.errorMessage != nil)
        #expect(try Data(contentsOf: visualizationURL) == externalVisualizationBytes,
            "A stale Apply must not overwrite an external .vis edit.")

        let sourceFixture = try MaterializationStyleFixture()
        defer { sourceFixture.remove() }
        let sourceProject = sourceFixture.root.appendingPathComponent(sourceFixture.manifest.associatedProjectRelativePath)
        let sourceVisualizationURL = sourceProject.deletingPathExtension().appendingPathExtension("vis")
        let sourceStore = WorkspaceStore(system: MaterializationStyleServices(),
            modelProvider: BackendModelProvider(client: sourceFixture.client))
        try await materializationOpen(sourceStore, project: sourceProject)
        let sourceMap = try #require(sourceStore.mapDocuments.first {
            $0.kind == .geometry && $0.name == sourceFixture.manifest.associatedMapName
        })
        await sourceStore.configureMapResultSources(sourceMap.id)
        let sourceRows = try await sourceStore.sourceMapLayerRows(sourceMap.id)
        let sourceRow = try #require(sourceRows.first {
            $0.node.sourceLocator?.associationKind == "Terrain"
                && $0.node.name == sourceFixture.manifest.associatedTerrainName
        })
        let sourceStyle = try await sourceStore.makeAssociatedRasterStyleSession(
            node: sourceRow.node, mapID: sourceMap.id)
        await sourceStyle.load()
        let sourceContext = try #require(sourceStyle.context)
        let styleSource = sourceContext.sourcePath
        let visualizationBeforeSourceChange = try Data(contentsOf: sourceVisualizationURL)
        var changedSource = try Data(contentsOf: URL(fileURLWithPath: styleSource))
        changedSource.append(0)
        try changedSource.write(to: URL(fileURLWithPath: styleSource), options: .atomic)
        var sourceDraft = try #require(sourceStyle.draft)
        sourceDraft.alpha = sourceDraft.alpha == 171 ? 170 : 171
        sourceStyle.draft = sourceDraft
        #expect(await sourceStyle.apply() == false)
        #expect(sourceStyle.errorMessage != nil)
        #expect(try Data(contentsOf: sourceVisualizationURL) == visualizationBeforeSourceChange,
            "A source-HDF revision mismatch must not write the visualization file.")
    }
}

private struct MaterializationStyleManifest: Decodable {
    let associatedProjectRelativePath: String
    let associatedMapName: String
    let associatedTerrainName: String
    let cpuProjectRelativePath: String
    let cpuMapName: String
    let cpuPlanName: String
    let cpuResultRelativePath: String
    let cpuResultRevision: String
}

private struct MaterializationStyleFixture {
    let root: URL
    let manifest: MaterializationStyleManifest
    let client: BackendProcessClient

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: try #require(environment["HECRAS_ASSOCIATED_STYLE_ACCEPTANCE_DIRECTORY"]))
        client = BackendProcessClient(executableURL: URL(fileURLWithPath:
            try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"])))
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("associated-style-materialization-" + UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: root)
        do {
            manifest = try JSONDecoder().decode(MaterializationStyleManifest.self,
                from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private func materializationSelectResult(_ store: WorkspaceStore,
                                         mapID: UUID,
                                         planName: String,
                                         resultURL: URL,
                                         revision: String) async throws {
    let state = store.mapState(for: mapID)
    let initial = try #require(state.resultSources.snapshot)
    let node = try #require(initial.sources.activeNodes.first {
        $0.nodeKind == "MultiResult" && $0.name == planName
    })
    let targetPath = SourceFilePaths.canonical(resultURL)
    let choice = try #require(node.selections.first(where: { $0.selectionIndex == 0 })?.choices.first {
        SourceFilePaths.canonical(URL(fileURLWithPath: $0.resultPath)) == targetPath
            && $0.revision.caseInsensitiveCompare(revision) == .orderedSame
    })
    await state.resultSources.setSelection(nodeID: node.id, selectionIndex: 0,
        mode: .explicit, choice: choice)
    // Selection changes can enqueue the usual background source refresh. Await
    // the same production workflow here so the test reports source/tree setup
    // failures directly instead of timing out while that work is still running.
    await store.configureMapResultSources(mapID)

    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    var lastState = "no selection state observed"
    while ContinuousClock.now < deadline {
        let selected = state.resultSources.snapshot?.sources.activeNodes
            .first(where: { $0.id == node.id })?.selections
            .first(where: { $0.selectionIndex == 0 })?.selectedResult
        let selectedMatches = selected.map {
            SourceFilePaths.canonical(URL(fileURLWithPath: $0.resultPath)) == targetPath
                && $0.revision.caseInsensitiveCompare(revision) == .orderedSame
        } ?? false
        let treeHasExactOwner = state.sourceMapLayerRows.contains { row in
            guard let locator = row.node.sourceLocator,
                  let parentPath = locator.parentResultAssetID,
                  let parentRevision = locator.parentResultRevision else { return false }
            return locator.parentResultNodeType == "MultiResult"
                && locator.parentResultNodeName == planName
                && SourceFilePaths.canonical(URL(fileURLWithPath: parentPath)) == targetPath
                && parentRevision.caseInsensitiveCompare(revision) == .orderedSame
        }
        let sourceIdentity = store.mapSourceWorkflowIdentity(mapID)
        let sourceIdentityMatches = state.resultSourceIdentity == sourceIdentity
        if !state.resultSources.isSelecting,
           selectedMatches,
           treeHasExactOwner,
           sourceIdentityMatches {
            return
        }
        let selectedDescription = selected.map {
            "\(SourceFilePaths.canonical(URL(fileURLWithPath: $0.resultPath)))#\($0.revision)"
        } ?? "none"
        let rowDescriptions = state.sourceMapLayerRows.compactMap { row -> String? in
            guard let locator = row.node.sourceLocator,
                  locator.parentResultNodeName == planName else { return nil }
            return "\(locator.nodeType):\(locator.parentResultNodeType ?? "-")@\(locator.parentResultAssetID ?? "-")#\(locator.parentResultRevision ?? "-")"
        }.prefix(4).joined(separator: ",")
        let storedIdentity = state.resultSourceIdentity.map { String($0.suffix(16)) } ?? "none"
        let currentIdentity = String(sourceIdentity.suffix(16))
        let setupGeneration = state.resultSourceSetupGeneration
        let downstream = [
            "geometry=\(state.projectGeometryMap.isLoading):\(state.projectGeometryMap.error ?? "-")",
            "associated=\(state.associatedMapLayers.isLoading):\(state.associatedMapLayers.errorMessage ?? "-")",
            "boundary=\(state.boundaryMap.isLoading):\(state.boundaryMap.errorMessage ?? "-")",
            "culvert=\(state.storedCulvertProfile.isLoading):\(state.storedCulvertProfile.errorMessage ?? "-")"
        ].joined(separator: ";")
        lastState = "selecting=\(state.resultSources.isSelecting), selectedMatches=\(selectedMatches), " +
            "sourceLoading=\(state.resultSources.isLoading), treeOwner=\(treeHasExactOwner), " +
            "sourceIdentityMatches=\(sourceIdentityMatches), generation=\(setupGeneration), " +
            "identity=\(storedIdentity)/\(currentIdentity), downstream=[\(downstream)], " +
            "selected=\(selectedDescription), rows=[\(rowDescriptions)], " +
            "sourceError=\(state.resultSources.errorMessage ?? "none")"
        try await Task.sleep(for: .milliseconds(20))
    }
    throw MaterializationStyleError.resultSourceSelectionTimedOut(String(lastState.prefix(1400)))
}

@MainActor
private func materializationOpen(_ store: WorkspaceStore, project: URL) async throws {
    store.requestOpen(project)
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while ContinuousClock.now < deadline {
        if store.document?.url?.standardizedFileURL == project.standardizedFileURL && !store.isOpeningProject {
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw MaterializationStyleError.projectOpenTimedOut
}

private func materializationRemoveAssociationRow(_ visualization: URL,
                                                 mapName: String,
                                                 nodeType: String,
                                                 nodeName: String) throws -> Bool {
    let document = try XMLDocument(contentsOf: visualization, options: [.nodePreserveAll])
    guard let maps = document.rootElement()?.elements(forName: "Maps").first,
          let map = maps.elements(forName: "Map").first(where: {
              $0.attribute(forName: "Name")?.stringValue == mapName
          }),
          let tree = map.elements(forName: "Tree").first,
          let nodes = tree.elements(forName: "Nodes").first,
          let matching = nodes.elements(forName: "Node").first(where: {
              $0.attribute(forName: "Type")?.stringValue == "Root"
                  && $0.attribute(forName: "Name")?.stringValue == "Matching Layers"
          }),
          let association = matching.elements(forName: "Node").first(where: {
              $0.attribute(forName: "Type")?.stringValue == nodeType
                  && $0.attribute(forName: "Name")?.stringValue == nodeName
          }) else { return false }
    association.detach()
    try document.xmlData(options: [.nodePreserveAll]).write(to: visualization, options: .atomic)
    return true
}

private func materializationFiles(in root: URL, excluding excludedURL: URL) throws -> [String: Data] {
    guard let enumerator = FileManager.default.enumerator(at: root,
        includingPropertiesForKeys: [.isRegularFileKey]) else {
        throw MaterializationStyleError.unreadableFixture
    }
    var files: [String: Data] = [:]
    let excludedPath = excludedURL.standardizedFileURL.path
    for case let url as URL in enumerator {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              url.standardizedFileURL.path != excludedPath else { continue }
        files[url.path] = try Data(contentsOf: url)
    }
    return files
}

@MainActor
private final class MaterializationStyleServices: WorkspaceSystemServices {
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

private enum MaterializationStyleError: Error, CustomStringConvertible {
    case projectOpenTimedOut
    case resultSourceSelectionTimedOut(String)
    case unreadableFixture

    var description: String {
        switch self {
        case .projectOpenTimedOut:
            return "The project did not open within the test deadline."
        case .resultSourceSelectionTimedOut(let state):
            return "The exact Result selection workflow did not converge: \(state)"
        case .unreadableFixture:
            return "The acceptance fixture could not be read."
        }
    }
}
