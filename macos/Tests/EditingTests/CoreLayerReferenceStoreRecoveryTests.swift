import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct CoreLayerReferenceStoreRecoveryTests {
    @Test(arguments: [false, true]) @MainActor
    func closedEditorCommitRebasesOnlyItsExactCapturedReference(replacedBeforeReceipt: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("core-layer-commit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CoreLayerStoreRecoveryModelProvider()
        let defaults = try #require(UserDefaults(suiteName: "CoreLayerCommit.\(UUID().uuidString)"))
        let store = WorkspaceStore(system: SourceWorkflowFixtureServices(recoveryFolder: root.appendingPathComponent("Recovery")),
            modelProvider: provider, launchConfiguration: WorkspaceLaunchConfiguration(arguments: ["--first-launch"]),
            applicationDefaults: defaults)
        store.createProject(name: "Commit", units: "SI", description: "", directory: root,
            projectionType: "Local", projectionValue: "SI")
        defer { store.releaseProjectOpenLock() }
        let projectURL = try #require(store.document?.url)
        let sourceURL = root.appendingPathComponent("External Boundary.h5")
        let oldRevision = String(repeating: "A", count: 64)
        let committedRevision = String(repeating: "B", count: 64)
        let replacementRevision = String(repeating: "D", count: 64)
        let reference = makeReference(sessionID: store.projectSessionID, projectURL: projectURL,
            sourceURL: sourceURL, kind: "boundaryCondition", revision: oldRevision, name: "Original")
        #expect(store.registerCoreLayerReference(reference, projectSessionID: store.projectSessionID, projectURL: projectURL))
        let context = try #require(store.captureCoreLayerRequestContext())
        let asset = ProjectAsset(url: sourceURL, section: .boundaryConditions)
        let editor = ModelEditorSession(provider: provider)
        await editor.load(asset, kind: .boundaryCondition)
        store.registerEditor(editor)
        let callback = try #require(editor.didSaveModelSnapshot)
        store.unregisterEditor(editor)
        #expect(store.editorSession(editor.id) == nil)
        if replacedBeforeReceipt {
            let replacement = makeReference(sessionID: store.projectSessionID, projectURL: projectURL,
                sourceURL: sourceURL, kind: "boundaryCondition", revision: replacementRevision, name: "Replacement")
            #expect(store.registerCoreLayerReference(replacement, projectSessionID: store.projectSessionID, projectURL: projectURL))
        }
        let receipt = EditorSnapshot(fields: ["BoundaryConditionCatalogSummary/Context_Name": "Committed"],
            rows: [:], samples: [:], canEdit: true, images: [:], sourceRevision: committedRevision)
        callback(asset, receipt, context, context.projectRevision)
        let current = try #require(store.captureCoreLayerRequestContext()?.references.first)
        #expect(current.sourceRevision == (replacedBeforeReceipt ? replacementRevision : committedRevision))
        #expect(current.name == (replacedBeforeReceipt ? "Replacement" : "Committed"))
        #expect(current.canonicalSourcePath == CoreLayerRequestContext.canonical(sourceURL))
    }

    @Test @MainActor
    func twoBrokenReferencesCanBeRemovedSequentiallyAndConflictedDraftsRemainClosable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-layer-store-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = CoreLayerStoreRecoveryModelProvider()
        let defaults = try #require(UserDefaults(suiteName: "CoreLayerStoreRecoveryTests.\(UUID().uuidString)"))
        let store = WorkspaceStore(
            system: SourceWorkflowFixtureServices(recoveryFolder: root.appendingPathComponent("Recovery")),
            modelProvider: provider,
            launchConfiguration: WorkspaceLaunchConfiguration(arguments: ["--first-launch"]),
            applicationDefaults: defaults)
        store.createProject(name: "Recovery", units: "SI", description: "", directory: root,
            projectionType: "Local", projectionValue: "SI")
        let projectURL = try #require(store.document?.url)
        let projectRevision = try #require(store.document?.sourceRevision)
        let sessionID = store.projectSessionID
        let geometryURL = root.appendingPathComponent("Missing Geometry.h5")
        let boundaryURL = root.appendingPathComponent("Missing Boundary.h5")
        let geometry = makeReference(sessionID: sessionID, projectURL: projectURL,
            sourceURL: geometryURL, kind: "geometry", revision: String(repeating: "A", count: 64),
            name: "Missing Geometry")
        let boundary = makeReference(sessionID: sessionID, projectURL: projectURL,
            sourceURL: boundaryURL, kind: "boundaryCondition", revision: String(repeating: "B", count: 64),
            name: "Missing Boundary")
        #expect(store.registerCoreLayerReference(geometry, projectSessionID: sessionID, projectURL: projectURL))
        #expect(store.registerCoreLayerReference(boundary, projectSessionID: sessionID, projectURL: projectURL))

        let geometryAsset = try #require(store.assets.first {
            SourceFilePaths.canonical($0.url) == geometry.canonicalSourcePath
        })
        let boundaryAsset = try #require(store.assets.first {
            SourceFilePaths.canonical($0.url) == boundary.canonicalSourcePath
        })
        let geometryEditor = ModelEditorSession(provider: provider)
        let boundaryEditor = ModelEditorSession(provider: provider)
        await geometryEditor.load(geometryAsset, kind: .geometry)
        await boundaryEditor.load(boundaryAsset, kind: .boundaryCondition)
        store.registerEditor(geometryEditor, primaryKind: .geometry)
        store.registerEditor(boundaryEditor, primaryKind: .boundaryCondition)
        store.openEditors = [.geometry, .boundaryCondition]
        geometryEditor.set(CoreLayerStoreRecoveryModelProvider.field, "unsaved geometry draft")
        boundaryEditor.set(CoreLayerStoreRecoveryModelProvider.field, "unsaved boundary draft")
        let geometryDraft = geometryEditor.fields
        let boundaryDraft = boundaryEditor.fields

        // The first removal marks its open editor conflicted. That stale-draft
        // lock must not make the second exact-reference recovery appear busy.
        try store.removeCoreLayerReference(geometry)
        #expect(geometryEditor.hasCoreLayerReferenceConflict && geometryEditor.isBusy)
        #expect(geometryEditor.fields == geometryDraft)
        #expect(geometryEditor.hasUnsavedEditorChanges)
        #expect(!store.hasBusyModelEditors)
        try store.removeCoreLayerReference(boundary)
        #expect(boundaryEditor.hasCoreLayerReferenceConflict && boundaryEditor.isBusy)
        #expect(boundaryEditor.fields == boundaryDraft)
        #expect(boundaryEditor.hasUnsavedEditorChanges)
        #expect(store.captureCoreLayerRequestContext()?.references.isEmpty == true)
        #expect(store.document?.sourceRevision == projectRevision)

        // Project-close asks for the user's decision rather than treating a
        // recoverable draft conflict as an operation that can never finish.
        store.requestClose()
        #expect(store.showDiscardConfirmation)
        store.cancelReplacement()

        store.requestCloseTab(.editor(.geometry))
        #expect(store.showCloseTabConfirmation)
        #expect(!store.pendingCloseTabAllowsSave)
        store.discardAndCloseTab()
        #expect(!store.openEditors.contains(.geometry))
        #expect(geometryEditor.fields[CoreLayerStoreRecoveryModelProvider.field] == "saved baseline")
        #expect(!geometryEditor.hasUnsavedEditorChanges)
        #expect(!geometryEditor.hasCoreLayerReferenceConflict)

        store.requestCloseTab(.editor(.boundaryCondition))
        #expect(store.showCloseTabConfirmation)
        store.discardAndCloseTab()
        #expect(!store.openEditors.contains(.boundaryCondition))
        #expect(boundaryEditor.fields[CoreLayerStoreRecoveryModelProvider.field] == "saved baseline")
        #expect(!boundaryEditor.hasUnsavedEditorChanges)
        #expect(!boundaryEditor.hasCoreLayerReferenceConflict)
        store.releaseProjectOpenLock()
    }

    private func makeReference(sessionID: UUID, projectURL: URL, sourceURL: URL,
                               kind: String, revision: String, name: String) -> CoreLayerReferenceCapture {
        CoreLayerReferenceCapture(
            referenceID: CoreLayerRequestContext.referenceID(projectSessionID: sessionID,
                projectURL: projectURL, kind: kind, sourceURL: sourceURL, sourceRevision: revision),
            projectSessionID: sessionID.uuidString,
            projectPath: CoreLayerRequestContext.canonical(projectURL),
            kind: kind, sourcePath: sourceURL.path,
            canonicalSourcePath: CoreLayerRequestContext.canonical(sourceURL),
            sourceRevision: revision, name: name)
    }
}

@MainActor
private final class CoreLayerStoreRecoveryModelProvider: ModelEditorProvider {
    static let field = "CoreLayerStoreRecovery/Description"

    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot {
        EditorSnapshot(fields: [Self.field: "saved baseline"], rows: [:], samples: [:],
            canEdit: true, images: [:], sourceRevision: String(repeating: "C", count: 64))
    }

    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws {}

    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot {
        throw CocoaError(.featureUnsupported)
    }
}
