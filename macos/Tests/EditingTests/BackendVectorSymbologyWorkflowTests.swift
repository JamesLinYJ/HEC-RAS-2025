import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendVectorSymbologyWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func productionWorkspaceProviderPersistsOrderedVectorStylesAndKeepsProjectDraftsIndependent() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let suite = "HECRAS2025.BackendVectorSymbology.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = GlobalVectorStylePreferences(defaults: defaults)
        let first = try await makeWorkspace(executable: executable, name: "Symbology A",
            preferences: preferences)
        defer { try? FileManager.default.removeItem(at: first.folder) }
        let projectBytes = try Data(contentsOf: first.projectURL)
        let sourceBytes = try Data(contentsOf: first.vectorURL)
        let provider = try #require(first.store.vectorSymbologyProvider)

        let globalContext = VectorSymbologyContext(projectSessionID: first.store.globalSymbologySessionID,
            mapID: MapState.projectMapID, assetID: nil, scope: .global)
        let globalSnapshot = try #require(try await provider.snapshot(globalContext))
        #expect(globalSnapshot.options.count == 25)
        #expect(Set(globalSnapshot.options.map(\.id)).count == 25)
        var globalOptions = globalSnapshot.options
        let globalLineIndex = try #require(globalOptions.firstIndex { $0.id == "Polyline_Line_Symbology" })
        globalOptions[globalLineIndex].style.penWidth = 2
        let globalUpdate = try await provider.apply(options: globalOptions,
            additionalOptions: globalSnapshot.additionalOptions, context: globalContext)
        first.store.installMapUpdate(globalUpdate, mapID: first.mapID)
        #expect(preferences.style(for: "Polyline_Line_Symbology")?.penWidth == 2)

        let context = try #require(first.store.vectorSymbologyContexts(mapID: first.mapID).first {
            $0.visualNode?.mapLayerType == "PolylinesVector"
        })
        let snapshot = try #require(try await provider.snapshot(context))
        #expect(snapshot.canEdit)
        let optionIndex = try #require(snapshot.options.firstIndex { $0.id == "Polyline_Line_Symbology" })
        let lineOption = snapshot.options[optionIndex]
        #expect(lineOption.columns.first { $0.name == "Class" }?.kind == .string)
        #expect(lineOption.columns.first { $0.name == "Metric" }?.kind.isNumeric == true)

        var options = snapshot.options
        options[optionIndex].style.penColor = "#FF123456"
        options[optionIndex].style.penWidth = 4
        let orderedRules = [
            VectorStyleRule(column: "Class", comparison: "equals", threshold: "MAIN", resultValue: "7"),
            VectorStyleRule(column: "Class", comparison: "equals", threshold: "MAIN", resultValue: "9")
        ]
        options[optionIndex].conditions[.penWidth] = orderedRules
        options[optionIndex].conditions[.penColor] = [
            VectorStyleRule(column: "Class", comparison: "equals", threshold: "MAIN", resultValue: "#80112233")
        ]
        let vertexIndex = try #require(options.firstIndex { $0.id == "Polyline_Vertex_Symbology" })
        options[vertexIndex].conditions[.fillColor] = [
            VectorStyleRule(column: "Class", comparison: "equals", threshold: "MAIN", resultValue: "#00ff00")
        ]

        first.store.descriptionDraft = "Unpublished description draft"
        first.store.activeMapState.currentExtent = .init(
            lowerLeft: .init(x: 0, y: 0), upperRight: .init(x: 10, y: 10))
        first.store.saveCurrentView()
        #expect(first.store.savedViews.count == 1)
        let visualizationURL = first.projectURL.deletingPathExtension().appendingPathExtension("vis")
        let beforeStyle = try Data(contentsOf: visualizationURL)
        #expect(try VisualizationDocument(projectURL: first.projectURL).views.isEmpty)

        let update = try await provider.apply(options: options,
            additionalOptions: snapshot.additionalOptions, context: context)
        #expect(update.preserveInteractionState)
        let mapState = first.store.mapState(for: first.mapID)
        let layerID = try #require(context.layerID)
        let sourceLayer = try #require(mapState.vectors(first.store.mapLayers).first { $0.id == layerID })
        let selectedFeature = try #require(sourceLayer.features.first)
        let selectedAsset = try #require(first.store.assets.first {
            SourceFilePaths.canonical($0.url) == SourceFilePaths.canonical(sourceLayer.url)
        })
        // Mirror VectorMapCanvas.selectFeature's real selection state: select
        // the owning asset/map and retain the stable source/component identity.
        first.store.select(selectedAsset)
        first.store.activateMap(first.mapID)
        mapState.selectedLayerID = layerID
        mapState.selectedFeatureID = selectedFeature.id
        mapState.selectedFeatureIdentity = selectedFeature.stableIdentity
        mapState.selectedLineIdentity = selectedFeature.pathStableIdentities.first
        first.store.selectedFeatureID = selectedFeature.id
        first.store.inspectorMode = .components
        first.store.showInspector = true
        first.store.installMapUpdate(update, mapID: first.mapID)

        #expect(mapState.selectedLayerID == layerID && mapState.selectedFeatureID == selectedFeature.id)
        #expect(mapState.selectedFeatureIdentity == selectedFeature.stableIdentity)
        #expect(mapState.selectedLineIdentity == selectedFeature.pathStableIdentities.first)
        #expect(first.store.selectedFeatureID == selectedFeature.id)
        #expect(first.store.inspectorMode == .components && first.store.showInspector)
        let presentation = try #require(mapState.vectorStyles[layerID])
        #expect(presentation.sourceFeatureOrdinalBindingVerified)
        #expect(presentation.values(for: "Polyline_Line_Symbology", sourceFeatureIndex: 0)?.penWidth == 7)
        #expect(presentation.values(for: "Polyline_Line_Symbology", sourceFeatureIndex: 1)?.penWidth == 4)
        #expect(presentation.values(for: "Polyline_Line_Symbology", sourceFeatureIndex: 0)?.penColor == "#80112233")
        #expect(presentation.values(for: "Polyline_Line_Symbology", sourceFeatureIndex: 1)?.penColor == "#FF123456")
        #expect(presentation.values(for: "Polyline_Vertex_Symbology", sourceFeatureIndex: 0)?.fillColor == "#FF00FF00")
        #expect(sourceLayer.features.compactMap(\.sourceFeatureIndex) == [0, 1])

        let afterStyle = try Data(contentsOf: visualizationURL)
        #expect(afterStyle != beforeStyle)
        #expect(try Data(contentsOf: first.projectURL) == projectBytes)
        #expect(try Data(contentsOf: first.vectorURL) == sourceBytes)
        #expect(first.store.descriptionDraft == "Unpublished description draft")
        #expect(first.store.savedViews.count == 1)
        #expect(first.store.hasUnsavedChanges)
        #expect(try VisualizationDocument(projectURL: first.projectURL).views.isEmpty)

        let currentContext = try #require(first.store.vectorSymbologyContexts(mapID: first.mapID).first {
            $0.visualNode == context.visualNode
        })
        let persisted = try await provider.snapshot(currentContext)
        let persistedLine = try #require(persisted?.options.first { $0.id == "Polyline_Line_Symbology" })
        #expect(persistedLine.style.penWidth == 4)
        #expect(persistedLine.style.penColor == "#FF123456")
        let persistedRules = persistedLine.conditions[.penWidth] ?? []
        #expect(persistedRules.map(\.resultValue) == ["7", "9"])
        #expect(persistedRules.allSatisfy { $0.column == "Class" && $0.comparison == "equals" && $0.threshold == "MAIN" })
        #expect(persistedLine.conditions[.penColor]?.first?.resultValue == "#80112233")

        let nextGlobal = try #require(try await provider.snapshot(globalContext))
        var nextGlobalOptions = nextGlobal.options
        let nextGlobalLine = try #require(nextGlobalOptions.firstIndex { $0.id == "Polyline_Line_Symbology" })
        nextGlobalOptions[nextGlobalLine].style.penWidth = 3
        nextGlobalOptions[nextGlobalLine].style.penColor = "#FFABCDEF"
        _ = try await provider.apply(options: nextGlobalOptions, additionalOptions: [], context: globalContext)
        let localAfterGlobalChange = try #require(try await provider.snapshot(currentContext))
        let unchangedLocal = try #require(localAfterGlobalChange.options.first { $0.id == "Polyline_Line_Symbology" })
        #expect(unchangedLocal.style.penWidth == 4 && unchangedLocal.style.penColor == "#FF123456")
        #expect(unchangedLocal.defaultStyle.penWidth == 3 && unchangedLocal.defaultStyle.penColor == "#FFABCDEF")
        #expect(mapState.vectorStyles[try #require(context.layerID)]?
            .values(for: "Polyline_Line_Symbology", sourceFeatureIndex: 0)?.penWidth == 7)
        #expect(try Data(contentsOf: visualizationURL) == afterStyle)
        #expect(try Data(contentsOf: first.projectURL) == projectBytes)
        #expect(try Data(contentsOf: first.vectorURL) == sourceBytes)

        let identity = try #require(context.visualNode)
        let styleIDs = try #require(identity.supportedStyleDefinitionIDs)
        let defaultsByID = Dictionary(uniqueKeysWithValues: styleIDs.map {
            ($0, first.store.effectiveVectorStyle(definitionID: $0))
        })
        let sourceDocument = try VisualizationDocument(projectURL: first.projectURL)
        let storedSettings = try sourceDocument.vectorVisualSettings(identity: identity, defaults: defaultsByID)
        let storedLine = try #require(storedSettings.options["Polyline_Line_Symbology"])
        #expect(storedLine.values.penWidth == 4 && storedLine.values.penColor == "#FF123456")
        #expect(storedLine.rules(for: .penWidth).map(\.resultValue) == ["7", "9"])
        #expect(storedLine.rules(for: .penWidth).allSatisfy {
            $0.column == "Class" && $0.comparison == "equals" && $0.threshold == "MAIN"
        })

        // A new preferences object and Store model an app restart. The global
        // width is shared with a separate project, while the explicit local
        // width in this project's .vis remains 4.
        let reopenedPreferences = GlobalVectorStylePreferences(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(reopenedPreferences.style(for: "Polyline_Line_Symbology")?.penWidth == 3)
        let firstProjectLock = first.projectURL.deletingLastPathComponent().appendingPathComponent(".lock")
        #expect(FileManager.default.fileExists(atPath: firstProjectLock.path))
        try closeVectorSymbologyStore(first.store)
        #expect(!FileManager.default.fileExists(atPath: firstProjectLock.path))
        let restartedA = try await openWorkspace(projectURL: first.projectURL, vectorURL: first.vectorURL,
            recoveryDirectory: first.folder.appendingPathComponent("Restart Recovery"),
            executable: executable, preferences: reopenedPreferences)
        let restartedProvider = try #require(restartedA.store.vectorSymbologyProvider)
        let restartedContext = try #require(restartedA.store.vectorSymbologyContexts(mapID: restartedA.mapID).first {
            $0.visualNode?.mapLayerType == "PolylinesVector"
        })
        let restartedSnapshot = try await restartedProvider.snapshot(restartedContext)
        #expect(try #require(restartedSnapshot?.options.first { $0.id == "Polyline_Line_Symbology" }).style.penWidth == 4)
        let restartedGlobal = try #require(try await restartedProvider.snapshot(
            VectorSymbologyContext(projectSessionID: restartedA.store.globalSymbologySessionID,
                mapID: MapState.projectMapID, assetID: nil, scope: .global)))
        #expect(restartedGlobal.options.count == 25)
        #expect(restartedGlobal.options.first { $0.id == "Polyline_Line_Symbology" }?.style.penWidth == 3)
        try closeVectorSymbologyStore(restartedA.store)

        let second = try await makeWorkspace(executable: executable, name: "Symbology B",
            preferences: reopenedPreferences)
        defer { try? FileManager.default.removeItem(at: second.folder) }
        let secondProvider = try #require(second.store.vectorSymbologyProvider)
        let secondContext = try #require(second.store.vectorSymbologyContexts(mapID: second.mapID).first {
            $0.visualNode?.mapLayerType == "PolylinesVector"
        })
        let secondSnapshot = try await secondProvider.snapshot(secondContext)
        #expect(try #require(secondSnapshot?.options.first { $0.id == "Polyline_Line_Symbology" }).style.penWidth == 3)
        try closeVectorSymbologyStore(second.store)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func externalVisualizationRevisionRejectsApplyWithoutOverwritingTheExternalBytes() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let suite = "HECRAS2025.BackendVectorSymbology.Stale.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let fixture = try await makeWorkspace(executable: executable, name: "Stale Symbology",
            preferences: GlobalVectorStylePreferences(defaults: defaults))
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let provider = try #require(fixture.store.vectorSymbologyProvider)
        let context = try #require(fixture.store.vectorSymbologyContexts(mapID: fixture.mapID).first {
            $0.visualNode?.mapLayerType == "PolylinesVector"
        })
        let snapshot = try #require(try await provider.snapshot(context))
        var options = snapshot.options
        let lineIndex = try #require(options.firstIndex { $0.id == "Polyline_Line_Symbology" })
        options[lineIndex].style.penWidth = 6

        let visualizationURL = fixture.projectURL.deletingPathExtension().appendingPathExtension("vis")
        var externalBytes = try Data(contentsOf: visualizationURL)
        externalBytes.append(contentsOf: Data("\n<!-- external edit -->\n".utf8))
        try externalBytes.write(to: visualizationURL)

        var rejected = false
        do {
            _ = try await provider.apply(options: options,
                additionalOptions: snapshot.additionalOptions, context: context)
        } catch {
            rejected = true
        }
        #expect(rejected)
        #expect(try Data(contentsOf: visualizationURL) == externalBytes)
        #expect(try Data(contentsOf: fixture.projectURL) == fixture.projectBytes)
        #expect(try Data(contentsOf: fixture.vectorURL) == fixture.sourceBytes)
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    func duplicateSourceInstancesPersistAndRenderIndependentStylesAndRules() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let suite = "HECRAS2025.BackendVectorSymbology.Duplicate.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = GlobalVectorStylePreferences(defaults: defaults)
        let fixture = try await makeWorkspace(executable: executable, name: "Duplicate Styles", preferences: preferences)
        let visualizationURL = fixture.projectURL.deletingPathExtension().appendingPathExtension("vis")
        let xml = try XMLDocument(data: Data(contentsOf: visualizationURL), options: [.nodeLoadExternalEntitiesNever])
        let node = try #require(try xml.nodes(forXPath: "//Node[@MapType='PolylinesVector']").first as? XMLElement)
        let duplicate = try #require(node.copy() as? XMLElement)
        duplicate.attribute(forName: "Name")?.stringValue = "Channels copy"
        duplicate.attribute(forName: "IsChecked")?.stringValue = "false"
        (node.parent as? XMLElement)?.addChild(duplicate)
        try xml.xmlData.write(to: visualizationURL)
        let fixtureProjectLock = fixture.projectURL.deletingLastPathComponent().appendingPathComponent(".lock")
        #expect(FileManager.default.fileExists(atPath: fixtureProjectLock.path))
        try closeVectorSymbologyStore(fixture.store)
        #expect(!FileManager.default.fileExists(atPath: fixtureProjectLock.path))
        let reopened = try await openWorkspace(projectURL: fixture.projectURL, vectorURL: fixture.vectorURL,
            recoveryDirectory: fixture.folder.appendingPathComponent("Duplicate Recovery"),
            executable: executable, preferences: preferences)
        let provider = try #require(reopened.store.vectorSymbologyProvider)
        let contexts = reopened.store.vectorSymbologyContexts(mapID: reopened.mapID)
        #expect(contexts.count == 2)
        let duplicateContext = try #require(contexts.first { $0.visualNode?.nodeName == "Channels copy" })
        let originalContext = try #require(contexts.first { $0.visualNode?.nodeName != "Channels copy" })
        #expect(duplicateContext.visualNode?.nodePath != originalContext.visualNode?.nodePath)
        let duplicateID = try #require(duplicateContext.layerID)
        let originalID = try #require(originalContext.layerID)
        #expect(duplicateID != originalID)

        let mapState = reopened.store.mapState(for: reopened.mapID)
        let instances = mapState.vectors(reopened.store.mapLayers)
        #expect(Set(instances.map(\.id)) == Set([duplicateID, originalID]))
        let hiddenDuplicate = try #require(instances.first { $0.id == duplicateID })
        let visibleOriginal = try #require(instances.first { $0.id == originalID })
        #expect(!hiddenDuplicate.isSourceVisible)
        #expect(hiddenDuplicate.features.compactMap(\.sourceFeatureIndex) == visibleOriginal.features.compactMap(\.sourceFeatureIndex))
        #expect(mapState.visibleVectors(reopened.store.mapLayers).contains { $0.id == originalID })
        #expect(!mapState.visibleVectors(reopened.store.mapLayers).contains { $0.id == duplicateID })

        let originalSnapshot = try #require(try await provider.snapshot(originalContext))
        let duplicateSnapshot = try #require(try await provider.snapshot(duplicateContext))
        #expect(originalSnapshot.canEdit && duplicateSnapshot.canEdit)
        #expect(originalSnapshot.options.first { $0.id == "Polyline_Line_Symbology" }?.conditionCapabilityReason == nil)
        #expect(duplicateSnapshot.options.first { $0.id == "Polyline_Line_Symbology" }?.conditionCapabilityReason == nil)

        let before = try Data(contentsOf: visualizationURL)
        var originalOptions = originalSnapshot.options
        let originalLineIndex = try #require(originalOptions.firstIndex { $0.id == "Polyline_Line_Symbology" })
        originalOptions[originalLineIndex].style.penColor = "#FF123456"
        originalOptions[originalLineIndex].style.penWidth = 4
        originalOptions[originalLineIndex].conditions[.penWidth] = [
            VectorStyleRule(column: "Class", comparison: "equals", threshold: "MAIN", resultValue: "7")
        ]
        let originalUpdate = try await provider.apply(options: originalOptions,
            additionalOptions: originalSnapshot.additionalOptions, context: originalContext)
        reopened.store.installMapUpdate(originalUpdate, mapID: reopened.mapID)
        #expect(try Data(contentsOf: visualizationURL) != before)

        await reopened.store.refreshVectorSymbologyContexts(mapID: reopened.mapID)
        let afterFirstWriteContexts = reopened.store.vectorSymbologyContexts(mapID: reopened.mapID)
        let refreshedDuplicate = try #require(afterFirstWriteContexts.first {
            $0.visualNode == duplicateContext.visualNode
        })
        let refreshedDuplicateSnapshot = try #require(try await provider.snapshot(refreshedDuplicate))
        var duplicateOptions = refreshedDuplicateSnapshot.options
        let duplicateLineIndex = try #require(duplicateOptions.firstIndex { $0.id == "Polyline_Line_Symbology" })
        duplicateOptions[duplicateLineIndex].style.penColor = "#FFABCDEF"
        duplicateOptions[duplicateLineIndex].style.penWidth = 8
        duplicateOptions[duplicateLineIndex].conditions[.penWidth] = [
            VectorStyleRule(column: "Class", comparison: "equals", threshold: "MAIN", resultValue: "9")
        ]
        let duplicateUpdate = try await provider.apply(options: duplicateOptions,
            additionalOptions: refreshedDuplicateSnapshot.additionalOptions, context: refreshedDuplicate)
        reopened.store.installMapUpdate(duplicateUpdate, mapID: reopened.mapID)
        await reopened.store.refreshVectorSymbologyContexts(mapID: reopened.mapID)

        let persistedContexts = reopened.store.vectorSymbologyContexts(mapID: reopened.mapID)
        let persistedOriginal = try #require(persistedContexts.first { $0.visualNode == originalContext.visualNode })
        let persistedDuplicate = try #require(persistedContexts.first { $0.visualNode == duplicateContext.visualNode })
        let originalAfter = try #require(try await provider.snapshot(persistedOriginal))
        let duplicateAfter = try #require(try await provider.snapshot(persistedDuplicate))
        let originalLine = try #require(originalAfter.options.first { $0.id == "Polyline_Line_Symbology" })
        let duplicateLine = try #require(duplicateAfter.options.first { $0.id == "Polyline_Line_Symbology" })
        #expect(originalLine.style.penWidth == 4 && originalLine.style.penColor == "#FF123456")
        #expect(duplicateLine.style.penWidth == 8 && duplicateLine.style.penColor == "#FFABCDEF")
        #expect(originalLine.conditions[.penWidth]?.map(\.resultValue) == ["7"])
        #expect(duplicateLine.conditions[.penWidth]?.map(\.resultValue) == ["9"])

        let originalPresentation = try #require(mapState.vectorStyles[originalID])
        let duplicatePresentation = try #require(mapState.vectorStyles[duplicateID])
        #expect(originalPresentation.base["Polyline_Line_Symbology"]?.penWidth == 4)
        #expect(duplicatePresentation.base["Polyline_Line_Symbology"]?.penWidth == 8)
        #expect(originalPresentation.values(for: "Polyline_Line_Symbology", sourceFeatureIndex: 0)?.penWidth == 7)
        #expect(duplicatePresentation.values(for: "Polyline_Line_Symbology", sourceFeatureIndex: 0)?.penWidth == 9)
        #expect(originalPresentation.values(for: "Polyline_Line_Symbology", sourceFeatureIndex: 1)?.penWidth == 4)
        #expect(duplicatePresentation.values(for: "Polyline_Line_Symbology", sourceFeatureIndex: 1)?.penWidth == 8)

        let document = try VisualizationDocument(projectURL: reopened.projectURL)
        let originalIdentity = try #require(persistedOriginal.visualNode)
        let duplicateIdentity = try #require(persistedDuplicate.visualNode)
        let originalDefinitionIDs = try #require(originalIdentity.supportedStyleDefinitionIDs)
        let duplicateDefinitionIDs = try #require(duplicateIdentity.supportedStyleDefinitionIDs)
        let originalDefaults = Dictionary(uniqueKeysWithValues: originalDefinitionIDs.map {
            ($0, reopened.store.effectiveVectorStyle(definitionID: $0))
        })
        let duplicateDefaults = Dictionary(uniqueKeysWithValues: duplicateDefinitionIDs.map {
            ($0, reopened.store.effectiveVectorStyle(definitionID: $0))
        })
        let storedOriginal = try document.vectorVisualSettings(identity: originalIdentity, defaults: originalDefaults)
        let storedDuplicate = try document.vectorVisualSettings(identity: duplicateIdentity, defaults: duplicateDefaults)
        #expect(storedOriginal.options["Polyline_Line_Symbology"]?.values.penWidth == 4)
        #expect(storedDuplicate.options["Polyline_Line_Symbology"]?.values.penWidth == 8)
        #expect(storedOriginal.options["Polyline_Line_Symbology"]?.rules(for: .penWidth).map(\.resultValue) == ["7"])
        #expect(storedDuplicate.options["Polyline_Line_Symbology"]?.rules(for: .penWidth).map(\.resultValue) == ["9"])
        #expect(try Data(contentsOf: reopened.projectURL) == reopened.projectBytes)
        #expect(try Data(contentsOf: reopened.vectorURL) == reopened.sourceBytes)
        try closeVectorSymbologyStore(reopened.store)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_MESH_PREPARE_ACCEPTANCE_DIRECTORY"] != nil))
    @MainActor
    func specializedGeometryOwnerInheritsGlobalEditsAndPreservesRulesAcrossStaleChecks() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixturePath = try #require(ProcessInfo.processInfo.environment["HECRAS_MESH_PREPARE_ACCEPTANCE_DIRECTORY"])
        let fixture = URL(fileURLWithPath: fixturePath, isDirectory: true).standardizedFileURL
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("specialized-vector-symbology-\(UUID().uuidString)", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        try FileManager.default.copyItem(at: fixture, to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        let projectURL = folder.appendingPathComponent("Prepared geometry.ras")
        let project = try ProjectDocument(contentsOf: projectURL)
        let geometry = try #require(project.assets.first { $0.section == .geometries && $0.isModelFile })
        let projectBytes = try Data(contentsOf: projectURL)
        let geometryBytes = try Data(contentsOf: geometry.url)
        let visualizationURL = projectURL.deletingPathExtension().appendingPathExtension("vis")
        try writeSpecializedGeometryVisualization(projectURL: projectURL, geometryName: geometry.name)
        let initialVisualizationBytes = try Data(contentsOf: visualizationURL)

        let suite = "HECRAS2025.SpecializedVectorSymbology.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suite))
        userDefaults.removePersistentDomain(forName: suite)
        defer { userDefaults.removePersistentDomain(forName: suite) }
        let preferences = GlobalVectorStylePreferences(defaults: userDefaults)
        let store = WorkspaceStore(
            system: SourceWorkflowFixtureServices(recoveryFolder: folder.appendingPathComponent("Recovery")),
            modelProvider: BackendModelProvider(client: BackendProcessClient(executableURL: URL(fileURLWithPath: executable))),
            globalVectorStylePreferences: preferences
        )
        store.requestOpen(projectURL)
        try await waitForProjectOpen(store)
        let mapID = try #require(store.catalogMapDocuments.first(where: { $0.kind == "Project" })
            .flatMap { UUID(uuidString: $0.id) })
        await store.refreshVectorSymbologyContexts(mapID: mapID)

        let provider = try #require(store.vectorSymbologyProvider)
        let context = try #require(store.vectorSymbologyContexts(mapID: mapID).first {
            $0.specializedNode?.nodeType == "FlowAreaLayer"
                && $0.specializedNode?.geometryName == geometry.name
        })
        #expect(context.visualNode == nil && context.specializedNode != nil)
        let initialSnapshot = try #require(try await provider.snapshot(context))
        #expect(initialSnapshot.canEdit && initialSnapshot.options.count == 1)
        let initialMeshStyle = try #require(initialSnapshot.options.first { $0.id == "Mesh_Line_Symbology" })
        #expect(!initialMeshStyle.conditionsEnabled)
        #expect(!initialMeshStyle.supportsAttributeConditions)
        #expect(initialMeshStyle.columns.isEmpty)
        #expect(initialMeshStyle.conditions[.penWidth]?.map(\.comparison) == ["VendorSpecificRule"])
        #expect(initialMeshStyle.style.penWidth == initialMeshStyle.defaultStyle.penWidth)

        let globalContext = VectorSymbologyContext(projectSessionID: store.globalSymbologySessionID,
            mapID: MapState.projectMapID, assetID: nil, scope: .global)
        let globalSnapshot = try #require(try await provider.snapshot(globalContext))
        var globalOptions = globalSnapshot.options
        let meshGlobalIndex = try #require(globalOptions.firstIndex { $0.id == "Mesh_Line_Symbology" })
        globalOptions[meshGlobalIndex].style.penWidth = 2.75
        _ = try await provider.apply(options: globalOptions, additionalOptions: [], context: globalContext)
        await store.refreshVectorSymbologyContexts(mapID: mapID)
        let inheritedContext = try #require(store.vectorSymbologyContexts(mapID: mapID).first {
            $0.specializedNode == context.specializedNode
        })
        let inheritedSnapshot = try #require(try await provider.snapshot(inheritedContext))
        let inheritedMeshStyle = try #require(inheritedSnapshot.options.first { $0.id == "Mesh_Line_Symbology" })
        #expect(inheritedMeshStyle.defaultStyle.penWidth == 2.75)
        #expect(inheritedMeshStyle.style.penWidth == 2.75)
        #expect(try Data(contentsOf: visualizationURL) == initialVisualizationBytes)

        var editedOptions = inheritedSnapshot.options
        let meshIndex = try #require(editedOptions.firstIndex { $0.id == "Mesh_Line_Symbology" })
        editedOptions[meshIndex].style.penWidth = 5.5
        let update = try await provider.apply(options: editedOptions,
            additionalOptions: inheritedSnapshot.additionalOptions, context: inheritedContext)
        store.installMapUpdate(update, mapID: mapID)
        #expect(try Data(contentsOf: visualizationURL) != initialVisualizationBytes)
        #expect(try Data(contentsOf: projectURL) == projectBytes)
        #expect(try Data(contentsOf: geometry.url) == geometryBytes)

        await store.refreshVectorSymbologyContexts(mapID: mapID)
        let savedContext = try #require(store.vectorSymbologyContexts(mapID: mapID).first {
            $0.specializedNode == context.specializedNode
        })
        let savedSnapshot = try #require(try await provider.snapshot(savedContext))
        let savedStyle = try #require(savedSnapshot.options.first { $0.id == "Mesh_Line_Symbology" })
        #expect(savedStyle.style.penWidth == 5.5)
        #expect(savedStyle.defaultStyle.penWidth == 2.75)
        #expect(savedStyle.conditions[.penWidth]?.map(\.comparison) == ["VendorSpecificRule"])

        let savedXML = try XMLDocument(data: Data(contentsOf: visualizationURL), options: [.nodeLoadExternalEntitiesNever])
        let savedRule = try #require(try savedXML.nodes(forXPath:
            "//Node[@Type='FlowAreaLayer']/Symbology[@ID='Mesh_Line_Symbology']/PenWidthConditions/Condition").first as? XMLElement)
        #expect(savedRule.attribute(forName: "Column")?.stringValue == "FutureMeshColumn")
        #expect(savedRule.attribute(forName: "Operator")?.stringValue == "VendorSpecificRule")
        #expect(savedRule.attribute(forName: "Threshold")?.stringValue == "mesh-token")
        #expect(savedRule.attribute(forName: "Result")?.stringValue == "17")
        #expect(try savedXML.nodes(forXPath:
            "//Node[@Type='FlowAreaLayer']/Symbology[@ID='Mesh_Line_Symbology']/PenWidthConditions/FutureCondition[@Keep='yes']").count == 1)
        #expect(try savedXML.nodes(forXPath:
            "//Node[@Type='FlowAreaLayer']/Symbology[@ID='Mesh_Line_Symbology']/FutureSymbologyRule[@Keep='yes']").count == 1)

        var staleOptions = savedSnapshot.options
        let savedMeshIndex = try #require(staleOptions.firstIndex { $0.id == "Mesh_Line_Symbology" })
        staleOptions[savedMeshIndex].style.penWidth = 8
        var externalBytes = try Data(contentsOf: visualizationURL)
        externalBytes.append(contentsOf: Data("\n<!-- external stale-revision edit -->\n".utf8))
        try externalBytes.write(to: visualizationURL)
        var rejectedStaleWrite = false
        do {
            _ = try await provider.apply(options: staleOptions,
                additionalOptions: savedSnapshot.additionalOptions, context: savedContext)
        } catch {
            rejectedStaleWrite = true
        }
        #expect(rejectedStaleWrite)
        #expect(try Data(contentsOf: visualizationURL) == externalBytes)
        #expect(try Data(contentsOf: projectURL) == projectBytes)
        #expect(try Data(contentsOf: geometry.url) == geometryBytes)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_MESH_PREPARE_ACCEPTANCE_DIRECTORY"] != nil))
    @MainActor
    func productionProviderLoadsBothNativeGeometryStyleChildrenWithoutWritingSourceFiles() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixturePath = try #require(ProcessInfo.processInfo.environment["HECRAS_MESH_PREPARE_ACCEPTANCE_DIRECTORY"])
        let fixture = URL(fileURLWithPath: fixturePath, isDirectory: true).standardizedFileURL
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Native Geometry Styles \(UUID().uuidString)", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        try FileManager.default.copyItem(at: fixture, to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        let projectURL = folder.appendingPathComponent("Prepared geometry.ras")
        let project = try ProjectDocument(contentsOf: projectURL)
        let geometry = try #require(project.assets.first { $0.section == .geometries && $0.isModelFile })
        let geometryBytes = try Data(contentsOf: geometry.url)
        let visualizationURL = projectURL.deletingPathExtension().appendingPathExtension("vis")
        try writeNativeGeometryStyleVisualization(projectURL: projectURL, geometryName: geometry.name)
        let projectBytes = try Data(contentsOf: projectURL)
        let visualizationBytes = try Data(contentsOf: visualizationURL)
        let visualizationXML = try XMLDocument(data: visualizationBytes, options: [.nodeLoadExternalEntitiesNever])
        let mapsElement = try #require(visualizationXML.rootElement()?.elements(forName: "Maps").first)
        let hasLegacyMapsAttribute = mapsElement.attributes?.contains { $0.name == "Maps" } ?? false
        #expect(!hasLegacyMapsAttribute)
        let savedMap = try #require(mapsElement.elements(forName: "Map").first)
        #expect(savedMap.attribute(forName: "Name")?.stringValue == "Geometry style review")
        #expect(savedMap.attribute(forName: "Type")?.stringValue == "Project")

        let suite = "HECRAS2025.NativeGeometryVectorSymbology.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suite))
        userDefaults.removePersistentDomain(forName: suite)
        defer { userDefaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(
            system: SourceWorkflowFixtureServices(recoveryFolder: folder.appendingPathComponent("Recovery")),
            modelProvider: BackendModelProvider(client: BackendProcessClient(executableURL: URL(fileURLWithPath: executable))),
            globalVectorStylePreferences: GlobalVectorStylePreferences(defaults: userDefaults)
        )
        store.requestOpen(projectURL)
        try await waitForProjectOpen(store)

        let map = try #require(store.catalogMapDocuments.first {
            $0.kind == "Project" && $0.name == "Geometry style review"
        })
        #expect(map.sourceIndex == 0)
        let mapID = try #require(UUID(uuidString: map.id))
        let nodes = try await store.sourceMapLayerNodes(mapID)
        let geometryNode = try #require(nodes.first { $0.sourceLocator?.nodeType == "Geometry" })
        let geometryLocator = try #require(geometryNode.sourceLocator)
        #expect(geometryNode.name == geometry.name)
        #expect(geometryLocator.rootName == "Geometries")
        #expect(geometryLocator.nodePath == [0, 0])
        #expect(geometryLocator.nodeName == geometry.name)
        if case .checked = geometryNode.checked {} else { Issue.record("The Geometry source node should be checked.") }
        let treeAssetPath = try #require(geometryNode.assetID)
        #expect(SourceFilePaths.canonical(URL(fileURLWithPath: treeAssetPath)) == SourceFilePaths.canonical(geometry.url))

        let conceptualNode = try #require(nodes.first { $0.sourceLocator?.nodeType == "ConceptualMesh" })
        let flowAreaNode = try #require(nodes.first { $0.sourceLocator?.nodeType == "FlowAreaLayer" })
        #expect(conceptualNode.sourceClass == "ConceptualMeshLayerVisualContext")
        #expect(flowAreaNode.sourceClass == "FlowAreaLayerVisualContext")
        #expect(conceptualNode.name == "Conceptual Mesh")
        #expect(flowAreaNode.name == "Computational Mesh")
        #expect(conceptualNode.sourceLocator?.rootName == "Geometries")
        #expect(conceptualNode.sourceLocator?.nodePath == [0, 0, 0])
        #expect(flowAreaNode.sourceLocator?.rootName == "Geometries")
        #expect(flowAreaNode.sourceLocator?.nodePath == [0, 0, 1])
        // Both retained source children expose independent check states. The
        // sparse XML fixture omits IsChecked, whose source default is false.
        if case .unchecked = conceptualNode.checked {} else { Issue.record("ConceptualMesh should retain its unchecked source default.") }
        if case .unchecked = flowAreaNode.checked {} else { Issue.record("FlowAreaLayer should retain its unchecked source default.") }

        await store.refreshVectorSymbologyContexts(mapID: mapID)
        let contexts = store.vectorSymbologyContexts(mapID: mapID)
        #expect(contexts.count == 2)
        #expect(Set(contexts.compactMap { $0.specializedNode?.nodeType }) == Set(["ConceptualMesh", "FlowAreaLayer"]))
        let provider = try #require(store.vectorSymbologyProvider)
        let conceptualContext = try #require(contexts.first { $0.specializedNode?.nodeType == "ConceptualMesh" })
        let flowAreaContext = try #require(contexts.first { $0.specializedNode?.nodeType == "FlowAreaLayer" })

        for (context, expectedType, expectedName, expectedPath) in [
            (conceptualContext, "ConceptualMesh", "Conceptual Mesh", [0, 0, 0]),
            (flowAreaContext, "FlowAreaLayer", "Computational Mesh", [0, 0, 1])
        ] {
            let owner = try #require(context.specializedNode)
            #expect(context.visualNode == nil)
            #expect(context.assetID == geometry.id)
            #expect(owner.nodeType == expectedType)
            #expect(owner.nodeName == expectedName)
            #expect(owner.mapName == "Geometry style review")
            #expect(owner.mapType == "Project")
            #expect(owner.rootName == "Geometries")
            #expect(owner.geometryNodePath == [0, 0])
            #expect(owner.nodePath == expectedPath)
            #expect(owner.geometryName == geometry.name)
            #expect(owner.geometryAssetID == geometry.id)
            #expect(SourceFilePaths.canonical(URL(fileURLWithPath: owner.geometryAssetID)) == SourceFilePaths.canonical(geometry.url))

            let snapshot = try #require(try await provider.snapshot(context))
            #expect(snapshot.canEdit)
            if expectedType == "ConceptualMesh" {
                #expect(Set(snapshot.options.map(\.id)) == Set([
                    "Arc_Line_Symbology", "Node_Symbology", "Deletable_Node_Symbology", "Internal_Point_Symbology"
                ]))
                #expect(snapshot.options.allSatisfy { $0.style == $0.defaultStyle })
            } else {
                #expect(snapshot.options.map(\.id) == ["Mesh_Line_Symbology"])
                let meshStyle = try #require(snapshot.options.first)
                #expect(meshStyle.style.penColor == "#FF007AFF")
                #expect(meshStyle.style.penWidth == 2)
            }
        }

        // This explicit Store refresh verifies identity re-resolution after an
        // asset-catalog revision. It does not model SwiftUI task scheduling.
        let oldIdentity = store.mapWorkflowIdentity(mapID)
        store.refreshAssets()
        #expect(store.mapWorkflowIdentity(mapID) != oldIdentity)
        await store.refreshVectorSymbologyContexts(mapID: mapID)
        let refreshedContexts = store.vectorSymbologyContexts(mapID: mapID)
        #expect(Set(refreshedContexts.compactMap { $0.specializedNode?.nodeType }) == Set(["ConceptualMesh", "FlowAreaLayer"]))
        for context in refreshedContexts {
            let snapshot = try #require(try await provider.snapshot(context))
            #expect(snapshot.canEdit)
        }

        #expect(try Data(contentsOf: projectURL) == projectBytes)
        #expect(try Data(contentsOf: geometry.url) == geometryBytes)
        #expect(try Data(contentsOf: visualizationURL) == visualizationBytes)
    }

    private func writeSpecializedGeometryVisualization(projectURL: URL, geometryName: String) throws {
        let root = XMLElement(name: "Ras")
        let document = XMLDocument(rootElement: root)
        document.characterEncoding = "UTF-8"

        let maps = XMLElement(name: "Maps")
        maps.addAttribute(XMLNode.attribute(withName: "Maps", stringValue: "Project") as! XMLNode)
        root.addChild(maps)
        let map = XMLElement(name: "Map")
        map.addAttribute(XMLNode.attribute(withName: "Name", stringValue: "Project") as! XMLNode)
        map.addAttribute(XMLNode.attribute(withName: "Type", stringValue: "Project") as! XMLNode)
        maps.addChild(map)

        let tree = XMLElement(name: "Tree")
        let nodes = XMLElement(name: "Nodes")
        let geometryRoot = XMLElement(name: "Node")
        geometryRoot.addAttribute(XMLNode.attribute(withName: "Type", stringValue: "Root") as! XMLNode)
        geometryRoot.addAttribute(XMLNode.attribute(withName: "Name", stringValue: "Geometries") as! XMLNode)
        let geometryNode = XMLElement(name: "Node")
        geometryNode.addAttribute(XMLNode.attribute(withName: "Type", stringValue: "Geometry") as! XMLNode)
        geometryNode.addAttribute(XMLNode.attribute(withName: "Name", stringValue: geometryName) as! XMLNode)
        geometryNode.addAttribute(XMLNode.attribute(withName: "IsChecked", stringValue: "true") as! XMLNode)
        let meshNode = XMLElement(name: "Node")
        meshNode.addAttribute(XMLNode.attribute(withName: "Type", stringValue: "FlowAreaLayer") as! XMLNode)
        meshNode.addAttribute(XMLNode.attribute(withName: "Name", stringValue: "Computational Mesh") as! XMLNode)
        let symbology = XMLElement(name: "Symbology")
        symbology.addAttribute(XMLNode.attribute(withName: "ID", stringValue: "Mesh_Line_Symbology") as! XMLNode)
        let conditions = XMLElement(name: "PenWidthConditions")
        let condition = XMLElement(name: "Condition")
        condition.addAttribute(XMLNode.attribute(withName: "Column", stringValue: "FutureMeshColumn") as! XMLNode)
        condition.addAttribute(XMLNode.attribute(withName: "Operator", stringValue: "VendorSpecificRule") as! XMLNode)
        condition.addAttribute(XMLNode.attribute(withName: "Threshold", stringValue: "mesh-token") as! XMLNode)
        condition.addAttribute(XMLNode.attribute(withName: "Result", stringValue: "17") as! XMLNode)
        conditions.addChild(condition)
        let futureCondition = XMLElement(name: "FutureCondition")
        futureCondition.addAttribute(XMLNode.attribute(withName: "Keep", stringValue: "yes") as! XMLNode)
        conditions.addChild(futureCondition)
        symbology.addChild(conditions)
        let futureRule = XMLElement(name: "FutureSymbologyRule")
        futureRule.addAttribute(XMLNode.attribute(withName: "Keep", stringValue: "yes") as! XMLNode)
        symbology.addChild(futureRule)
        meshNode.addChild(symbology)
        geometryNode.addChild(meshNode)
        geometryRoot.addChild(geometryNode)
        nodes.addChild(geometryRoot)
        tree.addChild(nodes)
        map.addChild(tree)

        try document.xmlData(options: [.nodePrettyPrint]).write(
            to: projectURL.deletingPathExtension().appendingPathExtension("vis"), options: .atomic)
    }

    private func writeNativeGeometryStyleVisualization(projectURL: URL, geometryName: String) throws {
        let root = XMLElement(name: "Ras")
        let document = XMLDocument(rootElement: root)
        document.characterEncoding = "UTF-8"

        func addAttribute(_ name: String, _ value: String, to element: XMLElement) {
            element.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode)
        }

        let maps = XMLElement(name: "Maps")
        let map = XMLElement(name: "Map")
        addAttribute("Name", "Geometry style review", to: map)
        addAttribute("Type", "Project", to: map)
        maps.addChild(map)
        root.addChild(maps)

        let tree = XMLElement(name: "Tree")
        let nodes = XMLElement(name: "Nodes")
        let geometryRoot = XMLElement(name: "Node")
        addAttribute("Type", "Root", to: geometryRoot)
        addAttribute("Name", "Geometries", to: geometryRoot)
        let geometryNode = XMLElement(name: "Node")
        addAttribute("Type", "Geometry", to: geometryNode)
        addAttribute("Name", geometryName, to: geometryNode)
        addAttribute("IsChecked", "true", to: geometryNode)

        let conceptualMesh = XMLElement(name: "Node")
        addAttribute("Type", "ConceptualMesh", to: conceptualMesh)
        addAttribute("Name", "Conceptual Mesh", to: conceptualMesh)
        let flowArea = XMLElement(name: "Node")
        addAttribute("Type", "FlowAreaLayer", to: flowArea)
        addAttribute("Name", "Computational Mesh", to: flowArea)
        let symbology = XMLElement(name: "Symbology")
        addAttribute("ID", "Mesh_Line_Symbology", to: symbology)
        addAttribute("PenColor", "#FF007AFF", to: symbology)
        addAttribute("PenWidth", "2", to: symbology)
        flowArea.addChild(symbology)

        geometryNode.addChild(conceptualMesh)
        geometryNode.addChild(flowArea)
        geometryRoot.addChild(geometryNode)
        nodes.addChild(geometryRoot)
        tree.addChild(nodes)
        map.addChild(tree)

        try document.xmlData(options: [.nodePrettyPrint]).write(
            to: projectURL.deletingPathExtension().appendingPathExtension("vis"), options: .atomic)
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    func sourceTreePhysicalPathAndRenderedSymlinkShareOneExactStyleOwner() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let suite = "HECRAS2025.BackendVectorSymbology.Alias.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try await makeWorkspace(executable: executable, name: "Alias Styles",
            preferences: GlobalVectorStylePreferences(defaults: defaults), vectorAlias: true)
        let provider = try #require(fixture.store.vectorSymbologyProvider)
        let context = try #require(fixture.store.vectorSymbologyContexts(mapID: fixture.mapID).first {
            $0.visualNode?.mapLayerType == "PolylinesVector"
        })
        let renderedLayer = try #require(fixture.store.mapState(for: fixture.mapID)
            .vectors(fixture.store.mapLayers).first { $0.id == context.layerID })
        #expect(renderedLayer.url.resolvingSymlinksInPath() == fixture.vectorURL.resolvingSymlinksInPath())
        #expect(context.layerID == renderedLayer.id)
        #expect(context.visualNode?.assetID == SourceFilePaths.canonical(fixture.vectorURL))
        #expect(context.layerID != context.visualNode?.assetID)
        let snapshot = try #require(try await provider.snapshot(context))
        #expect(snapshot.canEdit)
        var options = snapshot.options
        let line = try #require(options.firstIndex { $0.id == "Polyline_Line_Symbology" })
        options[line].style.penWidth = 9
        let update = try await provider.apply(options: options, additionalOptions: [], context: context)
        fixture.store.installMapUpdate(update, mapID: fixture.mapID)
        #expect(fixture.store.mapState(for: fixture.mapID).vectorStyles[try #require(context.layerID)]?
            .base["Polyline_Line_Symbology"]?.penWidth == 9)
        #expect(try Data(contentsOf: fixture.projectURL) == fixture.projectBytes)
        #expect(try Data(contentsOf: fixture.vectorURL) == fixture.sourceBytes)
    }

    @MainActor
    private func makeWorkspace(executable: String, name: String,
        preferences: GlobalVectorStylePreferences, vectorAlias: Bool = false) async throws -> VectorSymbologyWorkflowFixture {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vector-symbology-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let projectURL = folder.appendingPathComponent("\(name).ras")
        let project = try ProjectDocument(name: name, units: "SI")
        try project.save(to: projectURL)
        let vectorURL = try writeVector(in: folder)
        if vectorAlias {
            let backing = folder.appendingPathComponent("Channels backing.geojson")
            try FileManager.default.moveItem(at: vectorURL, to: backing)
            try FileManager.default.createSymbolicLink(at: vectorURL, withDestinationURL: backing)
        }
        return try await openWorkspace(projectURL: projectURL, vectorURL: vectorURL,
            recoveryDirectory: folder.appendingPathComponent("Recovery"), executable: executable,
            preferences: preferences, folder: folder)
    }

    @MainActor
    private func openWorkspace(projectURL: URL, vectorURL: URL, recoveryDirectory: URL,
        executable: String, preferences: GlobalVectorStylePreferences,
        folder: URL? = nil) async throws -> VectorSymbologyWorkflowFixture {
        let provider = BackendModelProvider(client: BackendProcessClient(executableURL: URL(fileURLWithPath: executable)))
        let store = WorkspaceStore(system: SourceWorkflowFixtureServices(recoveryFolder: recoveryDirectory),
            modelProvider: provider, globalVectorStylePreferences: preferences)
        store.requestOpen(projectURL)
        try await waitForProjectOpen(store)

        var mapID = store.catalogMapDocuments.first(where: { $0.kind == "Project" })
            .flatMap { UUID(uuidString: $0.id) }
        if mapID == nil {
            #expect(await store.createMapDocument(kind: .project))
            mapID = store.catalogMapDocuments.first(where: { $0.kind == "Project" })
                .flatMap { UUID(uuidString: $0.id) }
        }
        let selectedMapID = try #require(mapID)
        let asset = try #require(store.assets.first { SourceFilePaths.canonical($0.url) == SourceFilePaths.canonical(vectorURL) })
        var nodes = try await store.sourceMapLayerNodes(selectedMapID)
        let sourceAlreadyAdded = nodes.contains { node in
            node.sourceLocator?.nodeType == "MapLayer"
                && node.assetID.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0)) } == SourceFilePaths.canonical(vectorURL)
        }
        if !sourceAlreadyAdded {
            await store.addAssetsToMap([asset], mapID: selectedMapID)
            nodes = try await store.sourceMapLayerNodes(selectedMapID)
        }
        let lineNode = try #require(nodes.first { node in
            node.sourceLocator?.nodeType == "MapLayer"
                && node.sourceLocator?.mapType == "PolylinesVector"
                && node.assetID.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0)) } == SourceFilePaths.canonical(vectorURL)
        })
        #expect(lineNode.sourceLocator?.rootName != nil)
        await store.refreshSourceMapVectors(nodes, mapID: selectedMapID)
        await store.refreshVectorSymbologyContexts(mapID: selectedMapID)
        #expect(store.vectorSymbologyContexts(mapID: selectedMapID).contains {
            $0.visualNode?.nodePath == lineNode.sourceLocator?.nodePath
                && $0.visualNode?.mapLayerType == "PolylinesVector"
        })

        let projectBytes = try Data(contentsOf: projectURL)
        let sourceBytes = try Data(contentsOf: vectorURL)
        return VectorSymbologyWorkflowFixture(folder: folder ?? projectURL.deletingLastPathComponent(),
            projectURL: projectURL, vectorURL: vectorURL, mapID: selectedMapID,
            store: store, projectBytes: projectBytes, sourceBytes: sourceBytes)
    }

    private func writeVector(in folder: URL) throws -> URL {
        let mapLayerDirectory = folder.appendingPathComponent("Map Layers", isDirectory: true)
        try FileManager.default.createDirectory(at: mapLayerDirectory, withIntermediateDirectories: true)
        let vectorURL = mapLayerDirectory.appendingPathComponent("Channels.geojson")
        let bytes = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"Class":"MAIN","Metric":1.25},"geometry":{"type":"LineString","coordinates":[[0,0],[1,1]]}},{"type":"Feature","properties":{"Class":"OTHER","Metric":2.5},"geometry":{"type":"LineString","coordinates":[[2,0],[3,1]]}}]}"#.utf8)
        try bytes.write(to: vectorURL)
        return vectorURL
    }

    @MainActor
    private func waitForProjectOpen(_ store: WorkspaceStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (store.document == nil || store.isOpeningProject || store.isMapLoading) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!store.isOpeningProject)
        #expect(store.document != nil)
    }
}

@MainActor
private func closeVectorSymbologyStore(_ store: WorkspaceStore) throws {
    store.requestClose()
    if store.showDiscardConfirmation { store.discardAndContinue() }
    try #require(store.document == nil)
}

@MainActor
private struct VectorSymbologyWorkflowFixture {
    let folder: URL
    let projectURL: URL
    let vectorURL: URL
    let mapID: UUID
    let store: WorkspaceStore
    let projectBytes: Data
    let sourceBytes: Data
}
