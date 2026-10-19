import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@Suite(.serialized)
struct InitialConditionsStoreRecoveryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_CULVERT_PARTICLE_ACCEPTANCE_DIRECTORY"] != nil))
    @MainActor
    func realCommittedAttachmentRecoversAfterSheetCloseWithoutRepeatingTheSetter() async throws {
        let environment = ProcessInfo.processInfo.environment
        let executable = try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = URL(fileURLWithPath: try #require(environment["HECRAS_CULVERT_PARTICLE_ACCEPTANCE_DIRECTORY"]))
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("initial-conditions-store-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest = try JSONDecoder().decode(RecoveryFixtureManifest.self,
            from: Data(contentsOf: folder.appendingPathComponent("acceptance.json")))
        let projectURL = folder.appendingPathComponent(manifest.projectRelativePath)
        let boundaryURL = folder.appendingPathComponent(manifest.boundaryConditionRelativePath)
        let result = try #require(manifest.results.first { $0.role == "signed-flow" })
        let resultURL = folder.appendingPathComponent(result.path)
        let resultBytes = try Data(contentsOf: resultURL)
        let client = BackendProcessClient(executableURL: URL(fileURLWithPath: executable))
        let modelProvider = BackendModelProvider(client: client)
        let provider = LostReceiptInitialConditionsProvider(base: BackendBoundaryInitialConditionsProvider(client: client))
        let store = WorkspaceStore(system: SourceWorkflowFixtureServices(
            recoveryFolder: folder.appendingPathComponent("Recovery")),
            modelProvider: modelProvider, initialConditionsProvider: provider)
        store.requestOpen(projectURL)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while store.document?.url?.standardizedFileURL != projectURL.standardizedFileURL || store.isOpeningProject {
            guard ContinuousClock.now < deadline else { throw RecoveryFixtureError.projectOpenTimeout }
            try await Task.sleep(for: .milliseconds(10))
        }
        let asset = try #require(store.assets.first { $0.section == .boundaryConditions
            && $0.url.standardizedFileURL == boundaryURL.standardizedFileURL })
        let editor = store.primaryEditorSession(.boundaryCondition)
        await editor.load(asset, kind: .boundaryCondition)
        #expect(editor.loaded && editor.canEdit)
        let workflow = try store.boundaryInitialConditionsSession(for: editor)
        #expect(await workflow.inspect(resultURL: resultURL, timestamp: nil, numberCulture: "en-US"))

        // Another window on the same HDF owns a real draft. Attachment must
        // not discard it or invoke the source setter until it is resolved.
        let other = ModelEditorSession(provider: modelProvider)
        store.registerEditor(other)
        await other.load(asset, kind: .boundaryCondition)
        let field = try #require(BoundaryFieldReferences.find(suffix: "_Description",
            schemas: ["BoundaryConditionCatalogSummary", "BoundaryConditionsSummary"], values: other.fields))
        other.set(field.storageID, "Other window draft")
        #expect(other.hasUnsavedEditorChanges)
        #expect(!(await workflow.attach()))
        #expect(provider.attachCalls == 0)
        #expect(!store.isRunningInitialConditionsCommit)
        other.discardEdits()
        #expect(!other.hasUnsavedEditorChanges)

        // The real backend commits both files; only its returned response is
        // lost. The Store must keep the lease and the original operation ID.
        #expect(!(await workflow.attach()))
        let operationID = try #require(workflow.pendingOperationID)
        let receipt = try #require(provider.committedReceipt)
        let projectBytes = try Data(contentsOf: projectURL)
        let boundaryBytes = try Data(contentsOf: boundaryURL)
        #expect(provider.attachCalls == 1)
        #expect(store.isRunningInitialConditionsCommit)
        #expect(store.hasPendingInitialConditionsOperation(for: editor))
        workflow.close()
        let reopened = try store.boundaryInitialConditionsSession(for: editor)
        #expect(reopened === workflow)
        #expect(reopened.pendingOperationID == operationID)
        #expect(await reopened.refreshStatus())
        #expect(provider.attachCalls == 1 && provider.statusCalls == 1)
        #expect(!store.isRunningInitialConditionsCommit)
        #expect(!store.hasPendingInitialConditionsOperation(for: editor))
        #expect(editor.sourceFileRevision == receipt.model.revision)
        #expect(other.sourceFileRevision == receipt.model.revision)
        #expect(!editor.hasUnsavedEditorChanges && !other.hasUnsavedEditorChanges)
        #expect(store.document?.connections.filter { $0.name == receipt.connectionName }.count == 1)
        #expect(try Data(contentsOf: projectURL) == projectBytes)
        #expect(try Data(contentsOf: boundaryURL) == boundaryBytes)
        #expect(try Data(contentsOf: resultURL) == resultBytes)
    }
}

@MainActor
private final class LostReceiptInitialConditionsProvider: BoundaryInitialConditionsProvider {
    let base: BackendBoundaryInitialConditionsProvider
    private(set) var attachCalls = 0
    private(set) var statusCalls = 0
    private(set) var committedReceipt: BoundaryInitialConditionsReceipt?
    init(base: BackendBoundaryInitialConditionsProvider) { self.base = base }
    func inspect(_ request: BoundaryInitialConditionsInspectionRequest) async throws -> BoundaryInitialConditionsInspection {
        try await base.inspect(request)
    }
    func attach(_ request: BoundaryInitialConditionsAttachRequest) async throws -> BoundaryInitialConditionsReceipt {
        attachCalls += 1
        committedReceipt = try await base.attach(request)
        throw RecoveryFixtureError.responseLost
    }
    func status(_ request: BoundaryInitialConditionsAttachRequest) async throws -> BoundaryInitialConditionsOperationStatus {
        statusCalls += 1
        return try await base.status(request)
    }
}

private struct RecoveryFixtureManifest: Decodable {
    struct Result: Decodable { let role: String; let path: String }
    let projectRelativePath: String
    let boundaryConditionRelativePath: String
    let results: [Result]
}
private enum RecoveryFixtureError: Error { case projectOpenTimeout, responseLost }
