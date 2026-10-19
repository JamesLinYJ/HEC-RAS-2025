import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct RasterCalculatorSessionRevisionTests {
    @Test @MainActor
    func sameStableMapRefreshPreservesUnsavedEditAndRequiresExplicitSourceAdoption() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("raster-calculator-session-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let projectURL = folder.appendingPathComponent("Calculator.ras")
        let project = try ProjectDocument(name: "Calculator", units: "SI")
        try project.save(to: projectURL)
        try Data("<Ras><Maps><Map Name='Project Map' Type='Project'/></Maps></Ras>".utf8)
            .write(to: projectURL.deletingPathExtension().appendingPathExtension("vis"))

        let defaultsName = "RasterCalculatorSessionRevisionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let modelProvider = BackendModelProvider(client: BackendProcessClient(
            executableURL: URL(fileURLWithPath: "/no-backend-needed-for-this-test")))
        let store = WorkspaceStore(system: RasterCalculatorRevisionFixtureServices(),
            modelProvider: modelProvider,
            recentHistoryStore: RecentProjectHistoryStore(defaults: defaults))
        store.requestOpen(projectURL)
        let openDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.isOpeningProject && ContinuousClock.now < openDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!store.isOpeningProject)

        let mapID = MapState.projectMapID
        let mapCapture = try #require(store.mapIdentityRequest(for: mapID))
        let originalSource = makeSource(revision: String(repeating: "A", count: 64),
            profileTimes: ["t=0", "t=1"])
        let currentSource = makeSource(revision: String(repeating: "B", count: 64),
            profileTimes: ["t=0", "t=1"])
        let backend = FakeRasterCalculatorBackend(sources: [originalSource])
        let workflow = store.mapWorkflowIdentity(mapID)
        let recipe = RasterCalculatorRecipe(expression: "depth * factor", noDataBehavior: "WriteNDV",
            keyFrameVariableName: "depth",
            inputs: [RasterCalculatorInput(variableName: "depth", sourceID: originalSource.id,
                sourceRevision: originalSource.revision, kind: "resultMap", mapType: "Depth", isKeyFrame: true)],
            constants: [RasterCalculatorConstant(name: "factor", value: "2")])
        let renderer = CalculatorLayerRenderCoordinator(store: store, provider: backend,
            map: mapCapture, mapID: mapID, projectSessionID: store.projectSessionID,
            mapWorkflowIdentity: workflow, layerID: "calculator-edit", layerName: "Saved name",
            recipe: recipe, contextToken: String(repeating: "C", count: 64),
            sources: [originalSource], profiles: [
                RasterCalculatorProfile(index: 0, time: "t=0"),
                RasterCalculatorProfile(index: 1, time: "t=1")
            ], isDynamic: true)
        let frame = try MapRasterLayer(id: "calculator-edit", name: "Saved name", width: 1, height: 1,
            rgba: Data([10, 20, 30, 255]), lowerLeft: MapPoint(x: 0, y: 0),
            upperRight: MapPoint(x: 1, y: 1), sourceMapID: mapID)
        store.calculatorLayerRegistry.add(CalculatorMapLayerEntry(id: "calculator-edit",
            mapID: mapID, projectSessionID: store.projectSessionID,
            mapWorkflowIdentity: workflow, mapCapture: mapCapture, name: "Saved name",
            recipe: recipe, layer: frame,
            sourceExtent: MapSourceRasterBounds(minX: 0, minY: 0, maxX: 10, maxY: 10),
            profiles: [RasterCalculatorProfile(index: 0, time: "t=0"),
                       RasterCalculatorProfile(index: 1, time: "t=1")],
            selectedProfileIndex: 1, isDynamic: true, isVisible: true,
            contextToken: String(repeating: "C", count: 64), sources: [originalSource], renderer: renderer))

        let session = RasterCalculatorSession(store: store, mapID: mapID, viewport: { nil },
            editingLayerID: "calculator-edit", provider: backend)
        await session.load()
        #expect(session.recipe == recipe)
        #expect(session.layerName == "Saved name")
        #expect(session.selectedProfileIndex == 1)

        var unsavedRecipe = recipe
        unsavedRecipe.expression = "flow * factor + 9"
        unsavedRecipe.inputs[0].variableName = "flow"
        unsavedRecipe.keyFrameVariableName = "flow"
        unsavedRecipe.constants[0].value = "3"
        session.recipe = unsavedRecipe
        session.layerName = "Unsaved calculator name"
        #expect(await session.evaluate())
        #expect(session.previewLayer != nil)
        #expect(session.isPreviewCurrent)
        backend.sources = [currentSource]

        #expect(!(await session.addToMap()),
            "Add to Map must re-inspect inputs and reject a source revision that changed after Preview.")
        #expect(backend.evaluateCount == 1,
            "Add to Map must reject the cached frame before evaluating or submitting against the new revision.")
        #expect(store.calculatorLayerRegistry.allLayers(mapID: mapID,
            projectSessionID: store.projectSessionID, workflowIdentity: workflow).count == 1)
        #expect(session.previewLayer == nil)
        #expect(session.recipe == unsavedRecipe)

        let previousWorkflow = store.mapWorkflowIdentity(mapID)
        store.refreshAssets()
        #expect(store.mapWorkflowIdentity(mapID) != previousWorkflow)
        #expect(session.refreshForCurrentMap())
        let refreshDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while session.isLoading && ContinuousClock.now < refreshDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!session.isLoading)
        #expect(backend.inspectCount == 3)
        #expect(session.recipe == unsavedRecipe)
        #expect(session.layerName == "Unsaved calculator name")
        #expect(session.selectedProfileIndex == 1)
        #expect(session.previewLayer == nil)
        #expect(session.hasSourceRevisionMismatch)
        #expect(session.canAdoptCurrentSourceVersion(for: unsavedRecipe.inputs[0].id))

        session.adoptCurrentSourceVersion(for: unsavedRecipe.inputs[0].id)
        var adoptedRecipe = unsavedRecipe
        adoptedRecipe.inputs[0].sourceRevision = currentSource.revision
        #expect(session.recipe == adoptedRecipe)
        #expect(session.layerName == "Unsaved calculator name")
        #expect(session.selectedProfileIndex == 1)
        #expect(!session.hasSourceRevisionMismatch)

        backend.suspendNextInspection = true
        let cancelledInspectionCommit = Task { @MainActor in await session.addToMap() }
        let inspectionDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !backend.hasPendingInspection && ContinuousClock.now < inspectionDeadline {
            await Task.yield()
        }
        #expect(backend.hasPendingInspection, "The commit should suspend in its fresh source inspection.")
        cancelledInspectionCommit.cancel()
        backend.resumePendingInspection()
        #expect(!(await cancelledInspectionCommit.value),
            "A canceled inspection must not proceed to evaluation or map registration.")
        #expect(session.recipe == adoptedRecipe)
        #expect(session.layerName == "Unsaved calculator name")
        #expect(store.calculatorLayerRegistry.allLayers(mapID: mapID,
            projectSessionID: store.projectSessionID, mapType: "Project").count == 1)
        #expect(store.calculatorLayerRegistry.entries["calculator-edit"]?.recipe == recipe)
        #expect(store.calculatorLayerRegistry.entries["calculator-edit"]?.name == "Saved name")

        backend.suspendNextEvaluation = true
        let cancelledEvaluationCommit = Task { @MainActor in await session.addToMap() }
        let evaluationDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !backend.hasPendingEvaluation && ContinuousClock.now < evaluationDeadline {
            await Task.yield()
        }
        #expect(backend.hasPendingEvaluation, "The commit should suspend in its fresh evaluation.")
        cancelledEvaluationCommit.cancel()
        backend.resumePendingEvaluation()
        #expect(!(await cancelledEvaluationCommit.value),
            "A canceled evaluation must not register a layer or overwrite the user's recipe.")
        #expect(session.recipe == adoptedRecipe)
        #expect(session.layerName == "Unsaved calculator name")
        #expect(store.calculatorLayerRegistry.allLayers(mapID: mapID,
            projectSessionID: store.projectSessionID, mapType: "Project").count == 1)
        #expect(store.calculatorLayerRegistry.entries["calculator-edit"]?.recipe == recipe)
        #expect(store.calculatorLayerRegistry.entries["calculator-edit"]?.name == "Saved name")
    }

    @Test
    func currentSourceVersionAdoptionRequiresSameSourceKindAndMapType() {
        let revision = String(repeating: "A", count: 64)
        let updatedRevision = String(repeating: "B", count: 64)
        let input = RasterCalculatorInput(variableName: "depth", sourceID: "stable-source-id",
            sourceRevision: revision, kind: "resultMap", mapType: "Depth")
        let sameDisplayNameDifferentSource = makeSource(id: "other-source-id", name: "Same name",
            revision: updatedRevision, kind: "resultMap", mapTypes: ["Depth"], profileTimes: [])
        let wrongKind = makeSource(revision: updatedRevision, kind: "terrain", mapTypes: [], profileTimes: [])
        let wrongMapType = makeSource(revision: updatedRevision, kind: "resultMap",
            mapTypes: ["Velocity"], profileTimes: [])
        let currentVersion = makeSource(revision: updatedRevision, kind: "resultMap",
            mapTypes: ["Depth", "Velocity"], profileTimes: [])

        #expect(!RasterCalculatorSourceRevisionPolicy.canAdoptCurrentVersion(of: input,
            in: [sameDisplayNameDifferentSource]))
        #expect(!RasterCalculatorSourceRevisionPolicy.canAdoptCurrentVersion(of: input,
            in: [wrongKind]))
        #expect(!RasterCalculatorSourceRevisionPolicy.canAdoptCurrentVersion(of: input,
            in: [wrongMapType]))
        #expect(RasterCalculatorSourceRevisionPolicy.canAdoptCurrentVersion(of: input,
            in: [currentVersion]))
    }

    private func makeSource(id: String = "stable-source-id", name: String = "Result",
                            revision: String, kind: String = "resultMap",
                            mapTypes: [String] = ["Depth", "Velocity"],
                            profileTimes: [String]) -> RasterCalculatorSourceChoice {
        RasterCalculatorSourceChoice(id: id, kind: kind, name: name,
            assetPath: "/tmp/\(name).hdf", revision: revision,
            files: [], isAvailable: true, unavailableReason: nil, mapTypes: mapTypes,
            profileCount: profileTimes.count, profileTimes: profileTimes,
            noDataValue: nil, minX: 0, minY: 0, maxX: 10, maxY: 10)
    }
}

@MainActor
private final class FakeRasterCalculatorBackend: RasterCalculatorBackendProviding {
    var sources: [RasterCalculatorSourceChoice]
    var suspendNextInspection = false
    var suspendNextEvaluation = false
    private var pendingInspection: CheckedContinuation<Void, Never>?
    private var pendingEvaluation: CheckedContinuation<Void, Never>?
    private(set) var inspectCount = 0
    private(set) var evaluateCount = 0

    var hasPendingInspection: Bool { pendingInspection != nil }
    var hasPendingEvaluation: Bool { pendingEvaluation != nil }

    init(sources: [RasterCalculatorSourceChoice]) { self.sources = sources }

    func inspect(map: MapTreeMapIdentity) async throws -> RasterCalculatorInspectResult {
        inspectCount += 1
        if suspendNextInspection {
            suspendNextInspection = false
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pendingInspection = continuation
            }
        }
        return RasterCalculatorInspectResult(projectPath: map.projectPath,
            projectRevision: String(repeating: "D", count: 64), projectXmlSHA: map.projectXmlSHA,
            visualizationRevision: map.expectedVisualizationRevision, mapID: map.mapID,
            mapIndex: map.mapIndex, mapName: map.mapName, mapType: map.mapType,
            contextToken: String(repeating: "C", count: 64), defaultNoDataBehavior: "WriteNDV",
            noDataBehaviors: ["WriteNDV", "WriteZero", "Allow"], reservedConstants: [], sources: sources)
    }

    func evaluate(map: MapTreeMapIdentity, contextToken: String,
                  recipe: RasterCalculatorRecipe, layerID: String, layerName: String,
                  profileIndex: Int, viewport: RasterMapViewExtent,
                  expectedSources: [RasterCalculatorSourceChoice]) async throws
        -> (RasterCalculatorEvaluateResult, MapRasterLayer) {
        evaluateCount += 1
        if suspendNextEvaluation {
            suspendNextEvaluation = false
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pendingEvaluation = continuation
            }
        }
        let profiles: [RasterCalculatorProfile]
        let isDynamic = recipe.inputs.contains { $0.kind == "resultMap" }
        if let keyFrame = recipe.inputs.first(where: \.isKeyFrame),
           let source = expectedSources.first(where: { $0.id == keyFrame.sourceID }) {
            profiles = source.profileTimes.enumerated().map {
                RasterCalculatorProfile(index: $0.offset, time: $0.element)
            }
        } else {
            profiles = [RasterCalculatorProfile(index: 0, time: "static")]
        }
        let selectedIndex = isDynamic ? profileIndex : 0
        let payload = RasterCalculatorLayerPayload(id: layerID, mapID: map.mapID,
            name: layerName, width: 1, height: 1, rgba: Data([10, 20, 30, 255]),
            minX: 0, minY: 0, maxX: 10, maxY: 10)
        let result = RasterCalculatorEvaluateResult(projectPath: map.projectPath,
            projectRevision: String(repeating: "D", count: 64), projectXmlSHA: map.projectXmlSHA,
            visualizationRevision: map.expectedVisualizationRevision, mapID: map.mapID,
            mapIndex: map.mapIndex, mapName: map.mapName, mapType: map.mapType,
            contextToken: contextToken, layerID: layerID, layerName: layerName,
            recipe: recipe, isDynamic: isDynamic, profileCount: profiles.count,
            selectedProfileIndex: selectedIndex, selectedProfileTime: profiles[selectedIndex].time,
            profiles: profiles, minX: 0, minY: 0, maxX: 10, maxY: 10,
            layer: payload, sources: expectedSources)
        let image = try payload.makeLayer(expectedID: layerID,
            expectedMapID: UUID(uuidString: map.mapID)!)
        return (result, image)
    }

    func resumePendingInspection() {
        let continuation = pendingInspection
        pendingInspection = nil
        continuation?.resume()
    }

    func resumePendingEvaluation() {
        let continuation = pendingEvaluation
        pendingEvaluation = nil
        continuation?.resume()
    }
}

@MainActor
private final class RasterCalculatorRevisionFixtureServices: WorkspaceSystemServices {
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
