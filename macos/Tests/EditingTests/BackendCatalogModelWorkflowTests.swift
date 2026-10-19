import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

private struct CatalogActionFixtureManifest: Decodable {
    struct Model: Decodable { let kind: String; let name: String; let assetPath: String }
    let projectPath: String
    let models: [Model]
}

struct BackendCatalogModelWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_CATALOG_MODEL_ACTION_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func treeMenuDuplicatePublishesSourceAssociationsAndPreservesProjectDrafts() async throws {
        let fixture = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HECRAS_CATALOG_MODEL_ACTION_ACCEPTANCE_DIRECTORY"]))
        let executable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        let manifest = try JSONDecoder().decode(CatalogActionFixtureManifest.self, from: Data(contentsOf: fixture.appendingPathComponent("manifest.json")))
        for model in manifest.models {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tree-duplicate-" + UUID().uuidString)
            try FileManager.default.copyItem(at: fixture, to: folder)
            defer { try? FileManager.default.removeItem(at: folder) }
            let projectURL = folder.appendingPathComponent(manifest.projectPath)
            let projectBytes = try Data(contentsOf: projectURL)
            let client = BackendProcessClient(executableURL: executable)
            let provider = BackendModelProvider(client: client)
            let store = WorkspaceStore(system: SourceWorkflowFixtureServices(recoveryFolder: folder.appendingPathComponent("Recovery")), modelProvider: provider)
            store.requestOpen(projectURL)
            let deadline = ContinuousClock.now + .seconds(10)
            while store.isOpeningProject && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(!store.isOpeningProject)
            let project = try #require(store.document)
            let asset = try #require(store.assets.first { $0.name == model.name })
            let kind = try #require(CatalogManagedModelKind(rawValue: model.kind))
            let originalBytes = try Data(contentsOf: asset.url)
            store.descriptionDraft = "Preserve menu duplicate draft 中文"
            let presentation = CatalogModelActionPresentation(asset: asset, kind: kind,
                intent: .duplicate, caller: .projectTree, store: store)
            store.catalogModelActionPresentation = presentation
            let coordinator = CatalogModelActionCoordinator(store: store)
            await coordinator.inspect(presentation)
            #expect(coordinator.error == nil)
            #expect(coordinator.isRequestedActionAvailable(presentation))
            let oldAssetIDs = Set(store.assets.map(\.id))
            #expect(await coordinator.perform(presentation))
            #expect(coordinator.error == nil)
            #expect(store.catalogModelActionPresentation == nil)
            let duplicate = try #require(store.assets.first { !oldAssetIDs.contains($0.id) && $0.section == asset.section })
            let reopened = try await provider.load(duplicate, kind: catalogFixtureEditorKind(model.kind))
            #expect(reopened.fields.values.contains(duplicate.name))
            #expect(try Data(contentsOf: asset.url) == originalBytes)
            #expect(try Data(contentsOf: projectURL) == projectBytes)
            #expect(store.descriptionDraft == "Preserve menu duplicate draft 中文")
            if model.kind == "Geometry" {
                let original = try #require(project.associationRows(group: "GeometryAssociations").first { $0.name == asset.name })
                let copied = try #require(project.associationRows(group: "GeometryAssociations").first { $0.name == duplicate.name })
                #expect(copied.fields["Terrain"] == original.fields["Terrain"])
                #expect(try #require(copied.fields["N_Values"]) == #require(original.fields["N_Values"]))
                #expect(store.isModified)
            } else if model.kind == "Plan" {
                let original = try #require(project.associationRows(group: "PlanAssociations").first { $0.name == asset.name })
                let copied = try #require(project.associationRows(group: "PlanAssociations").first { $0.name == duplicate.name })
                #expect(copied.fields["Geometry"] == original.fields["Geometry"])
                #expect(copied.fields["BoundaryCondition"] == original.fields["BoundaryCondition"])
                #expect(store.isModified)
            }
            #expect(!store.isRunningProjectTool)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_CATALOG_MODEL_ACTION_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func failedTerrainBackingTrashRestoresRealHDFRasterAndAssociationDraft() async throws {
        let fixture = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HECRAS_CATALOG_MODEL_ACTION_ACCEPTANCE_DIRECTORY"]))
        let executable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        let manifest = try JSONDecoder().decode(CatalogActionFixtureManifest.self, from: Data(contentsOf: fixture.appendingPathComponent("manifest.json")))
        let model = try #require(manifest.models.first { $0.kind == "Terrain" })
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-rollback-" + UUID().uuidString)
        try FileManager.default.copyItem(at: fixture, to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let projectURL = folder.appendingPathComponent(manifest.projectPath)
        let services = SourceWorkflowFixtureServices(recoveryFolder: folder.appendingPathComponent("Recovery"))
        services.failTrashCall = 2
        let client = BackendProcessClient(executableURL: executable)
        let actions = BackendCatalogModelActionProvider(client: client)
        let store = WorkspaceStore(system: services, modelProvider: BackendModelProvider(client: client))
        store.requestOpen(projectURL)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while store.isOpeningProject && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let project = try #require(store.document)
        let asset = try #require(store.assets.first { $0.name == model.name })
        let xml = project.editorXML
        let request = CatalogModelActionRequest(projectPath: projectURL.path, projectXml: xml, assetPath: asset.url.path,
            kind: "Terrain", expectedAssetSHA: CatalogModelActionPublisher.digest(try Data(contentsOf: asset.url)), action: "delete", name: nil)
        let owner = store.projectSessionID
        #expect(store.beginCatalogModelAction(assetID: asset.id, projectSessionID: owner))
        defer { store.endCatalogModelAction(projectSessionID: owner) }
        let receipt = try await actions.perform(request)
        let trash = try #require(receipt.trashPaths)
        #expect(trash.count >= 2)
        let bytes = try Dictionary(uniqueKeysWithValues: trash.map { ($0.path, try Data(contentsOf: URL(fileURLWithPath: $0.path))) })
        #expect(throws: (any Error).self) {
            try store.applyCatalogModelAction(receipt, assetID: asset.id, projectSessionID: owner)
        }
        #expect(services.trashCalls == 2)
        for (path, before) in bytes { #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before) }
        #expect(project.editorXML == xml)
        #expect(store.assets.contains { $0.id == asset.id })
        #expect(!store.isModified)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_CATALOG_MODEL_ACTION_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func allSixSourceModelKindsDuplicateRenameDeleteAndReopenWithoutSavingProjectDrafts() async throws {
        let fixture = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HECRAS_CATALOG_MODEL_ACTION_ACCEPTANCE_DIRECTORY"]))
        let executable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        let manifest = try JSONDecoder().decode(CatalogActionFixtureManifest.self, from: Data(contentsOf: fixture.appendingPathComponent("manifest.json")))
        #expect(Set(manifest.models.map(\.kind)) == Set(["Geometry", "Plan", "Terrain", "BoundaryCondition", "NValue", "Classification"]))
        for model in manifest.models {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-" + model.kind + "-" + UUID().uuidString)
            try FileManager.default.copyItem(at: fixture, to: folder)
            defer { try? FileManager.default.removeItem(at: folder) }
            let projectURL = folder.appendingPathComponent(manifest.projectPath)
            let projectBytes = try Data(contentsOf: projectURL)
            let client = BackendProcessClient(executableURL: executable)
            let provider = BackendModelProvider(client: client)
            let actions = BackendCatalogModelActionProvider(client: client)
            let services = SourceWorkflowFixtureServices(recoveryFolder: folder.appendingPathComponent("Recovery"))
            let store = WorkspaceStore(system: services, modelProvider: provider)
            store.requestOpen(projectURL)
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while store.isOpeningProject && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(!store.isOpeningProject)
            let project = try #require(store.document)
            let asset = try #require(store.assets.first { $0.name == model.name })
            let original = try Data(contentsOf: asset.url)
            store.descriptionDraft = "Preserve unsaved project description 中文"
            let clone = try await executeCatalogFixtureAction("clone", name: nil, asset: asset, kind: model.kind,
                store: store, actions: actions)
            let clonePath = try #require(clone.newAssetPath)
            #expect(FileManager.default.fileExists(atPath: clonePath))
            let cloneAsset = try #require(store.assets.first { $0.url.resolvingSymlinksInPath().path == URL(fileURLWithPath: clonePath).resolvingSymlinksInPath().path })
            let cloneSnapshot = try await provider.load(cloneAsset, kind: catalogFixtureEditorKind(model.kind))
            #expect(cloneSnapshot.fields.values.contains(cloneAsset.name))
            #expect(try Data(contentsOf: asset.url) == original)
            #expect(services.trashCalls == 0)
            let renamedName = model.name + " renamed 中文"
            let renamed = try await executeCatalogFixtureAction("rename", name: renamedName, asset: asset,
                kind: model.kind, store: store, actions: actions)
            #expect(!FileManager.default.fileExists(atPath: asset.url.path))
            let renamedPath = try #require(renamed.newAssetPath)
            let renamedAsset = try #require(store.assets.first { $0.url.resolvingSymlinksInPath().path == URL(fileURLWithPath: renamedPath).resolvingSymlinksInPath().path })
            #expect(renamedAsset.name == renamedName)
            let snapshot = try await provider.load(renamedAsset, kind: catalogFixtureEditorKind(model.kind))
            #expect(snapshot.fields.values.contains(renamedName))
            #expect(try Data(contentsOf: projectURL) == projectBytes)
            #expect(store.descriptionDraft == "Preserve unsaved project description 中文")
            if model.kind == "Geometry" {
                #expect(project.associationRows(group: "PlanAssociations").contains { $0.fields["Geometry"] == renamedName })
                #expect(project.associationRows(group: "GeometryAssociations").contains { $0.name == renamedName })
            }
            if model.kind == "Plan" {
                #expect(project.associationRows(group: "PlanAssociations").contains { $0.name == renamedName })
            }
            if model.kind == "Classification" {
                #expect(renamed.stagedTargets.contains { $0.expectedTargetSHA != nil })
                let nvalue = try #require(store.assets.first { $0.name == manifest.models.first(where: { $0.kind == "NValue" })?.name })
                let independent = try await provider.load(nvalue, kind: .surface)
                let classificationPath = try #require(independent.fields["ClassificationLayerManningNEditor/NValueLayer_ClassificationLayer"])
                #expect(!classificationPath.hasPrefix("missing:"))
                #expect(URL(fileURLWithPath: classificationPath).lastPathComponent == renamedAsset.url.lastPathComponent)
            }
            _ = try await executeCatalogFixtureAction("delete", name: nil, asset: renamedAsset,
                kind: model.kind, store: store, actions: actions)
            #expect(!FileManager.default.fileExists(atPath: renamedPath))
            #expect(FileManager.default.fileExists(atPath: clonePath))
            #expect(try Data(contentsOf: projectURL) == projectBytes)
            #expect(store.descriptionDraft == "Preserve unsaved project description 中文")
            #expect(!store.isRunningProjectTool)
        }
    }
}

@MainActor
private func executeCatalogFixtureAction(_ action: String, name: String?, asset: ProjectAsset, kind: String,
    store: WorkspaceStore, actions: BackendCatalogModelActionProvider) async throws -> CatalogModelActionReceipt {
    let project = try #require(store.document)
    let url = try #require(project.url)
    let owner = store.projectSessionID
    #expect(store.beginCatalogModelAction(assetID: asset.id, projectSessionID: owner))
    defer { store.endCatalogModelAction(projectSessionID: owner) }
    let request = CatalogModelActionRequest(projectPath: url.path, projectXml: project.editorXML,
        assetPath: asset.url.path, kind: kind, expectedAssetSHA: CatalogModelActionPublisher.digest(try Data(contentsOf: asset.url)),
        action: action, name: name)
    let receipt = try await actions.perform(request)
    do { try store.applyCatalogModelAction(receipt, assetID: asset.id, projectSessionID: owner) }
    catch { await actions.cleanup(receipt); throw error }
    await actions.cleanup(receipt)
    return receipt
}

private func catalogFixtureEditorKind(_ kind: String) -> ModelEditorKind {
    switch kind {
    case "Geometry": .geometry
    case "Plan": .plan
    case "Terrain": .terrain
    case "BoundaryCondition": .boundaryCondition
    default: .surface
    }
}
