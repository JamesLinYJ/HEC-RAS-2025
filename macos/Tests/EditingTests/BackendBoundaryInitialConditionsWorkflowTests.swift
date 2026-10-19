import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendBoundaryInitialConditionsWorkflowTests {
    @Test @MainActor
    func closingAnInspectionDoesNotInstallItsLateReply() async throws {
        let provider = HeldBoundaryInitialConditionsProvider()
        let capture = makeInitialConditionsCapture()
        let session = BoundaryInitialConditionsSession(provider: provider)
        session.configure(capture: capture, isCurrent: { $0.id == capture.id },
            beginCommit: { _, _ in true }, endCommit: { _ in }, commit: { _, _ in true })
        let resultURL = URL(fileURLWithPath: "/tmp/late-result.h5")

        let inspection = Task { @MainActor in
            await session.inspect(resultURL: resultURL, timestamp: "17-Oct-2026 00:15", numberCulture: "en-US")
        }
        try await waitUntil("inspection request", condition: { provider.pendingInspection != nil })
        session.close()
        provider.completeInspection(makeInspection(for: try #require(provider.inspectionRequests.first)))

        #expect(await inspection.value == false)
        #expect(session.inspection == nil)
        #expect(!session.isInspecting)
        #expect(session.pendingOperationID == nil)
    }

    @Test @MainActor
    func lostAttachReceiptUsesJournalAndNotFoundCanBeExplicitlyCancelled() async throws {
        let provider = HeldBoundaryInitialConditionsProvider()
        let capture = makeInitialConditionsCapture()
        let session = BoundaryInitialConditionsSession(provider: provider)
        var endOperationIDs: [String] = []
        session.configure(capture: capture, isCurrent: { $0.id == capture.id },
            beginCommit: { _, _ in true }, endCommit: { endOperationIDs.append($0) },
            commit: { _, _ in true })
        provider.nextInspection = makeInspection(for: .init(model: capture.model,
            projectRevision: capture.projectRevision, resultPath: "/tmp/initial-conditions-result.h5",
            timestamp: nil, numberCulture: nil))
        #expect(await session.inspect(resultURL: URL(fileURLWithPath: "/tmp/initial-conditions-result.h5"),
            timestamp: nil, numberCulture: nil))

        provider.nextAttachError = InitialConditionsFixtureError.lostResponse
        #expect(!(await session.attach()))
        let operationID = try #require(session.pendingOperationID)
        #expect(provider.attachRequests.count == 1)
        #expect(session.canRetry)

        provider.nextStatus = .init(state: .notFound, receipt: nil, errorMessage: nil)
        #expect(await session.refreshStatus())
        #expect(session.canCancelUnstartedOperation)
        #expect(session.cancelUnstartedOperation())
        #expect(session.pendingOperationID == nil)
        #expect(endOperationIDs == [operationID])
        #expect(provider.attachRequests.count == 1)
        #expect(session.errorMessage == L10n.text("No attachment was saved."))
    }

    @Test @MainActor
    func lostReceiptAfterCloseRecoversCommittedJournalWithoutResendingAttach() async throws {
        let provider = HeldBoundaryInitialConditionsProvider()
        let originalCapture = makeInitialConditionsCapture(id: "capture-before-close")
        let reopenedCapture = makeInitialConditionsCapture(id: "capture-after-reopen")
        let session = BoundaryInitialConditionsSession(provider: provider)
        var committedCaptures: [String] = []
        var endedOperations: [String] = []
        func configure(_ capture: BoundaryInitialConditionsCapture) {
            session.configure(capture: capture, isCurrent: { $0.id == capture.id },
                beginCommit: { _, _ in true }, endCommit: { endedOperations.append($0) },
                commit: { captured, _ in committedCaptures.append(captured.id); return true })
        }
        configure(originalCapture)
        let resultURL = URL(fileURLWithPath: "/tmp/initial-conditions-committed-recovery.h5")
        provider.nextInspection = makeInspection(for: .init(model: originalCapture.model,
            projectRevision: originalCapture.projectRevision, resultPath: resultURL.path,
            timestamp: nil, numberCulture: nil))
        #expect(await session.inspect(resultURL: resultURL, timestamp: nil, numberCulture: nil))

        provider.nextAttachError = InitialConditionsFixtureError.lostResponse
        #expect(!(await session.attach()))
        let frozenRequest = try #require(provider.attachRequests.first)
        #expect(session.pendingOperationID == frozenRequest.operationID)

        session.close()
        configure(reopenedCapture)
        provider.nextStatus = .init(state: .committed,
            receipt: makeReceipt(for: frozenRequest, alreadyCommitted: true), errorMessage: nil)
        #expect(await session.retry())

        #expect(provider.attachRequests.count == 1)
        #expect(provider.statusRequests.count == 1)
        #expect(provider.statusRequests[0].operationID == frozenRequest.operationID)
        #expect(committedCaptures == [originalCapture.id])
        #expect(endedOperations == [frozenRequest.operationID])
        #expect(session.receipt?.operationID == frozenRequest.operationID)
        #expect(session.receipt?.alreadyCommitted == true)
        #expect(session.pendingOperationID == nil)
        #expect(session.capture?.id == reopenedCapture.id)
        #expect(!(await session.retry()))
        #expect(provider.attachRequests.count == 1)
        #expect(committedCaptures == [originalCapture.id])
    }

    @Test @MainActor
    func preparedJournalRetryReusesTheExactFrozenOperationAndPayload() async throws {
        let provider = HeldBoundaryInitialConditionsProvider()
        let capture = makeInitialConditionsCapture()
        let session = BoundaryInitialConditionsSession(provider: provider)
        var committed = 0
        session.configure(capture: capture, isCurrent: { $0.id == capture.id },
            beginCommit: { _, _ in true }, endCommit: { _ in }, commit: { _, _ in committed += 1; return true })
        let resultURL = URL(fileURLWithPath: "/tmp/initial-conditions-prepared-retry.h5")
        provider.nextInspection = makeInspection(for: .init(model: capture.model,
            projectRevision: capture.projectRevision, resultPath: resultURL.path,
            timestamp: "17-Oct-2026 00:15", numberCulture: "en-US"))
        #expect(await session.inspect(resultURL: resultURL, timestamp: "17-Oct-2026 00:15", numberCulture: "en-US"))

        provider.nextAttachError = InitialConditionsFixtureError.lostResponse
        #expect(!(await session.attach()))
        let firstRequest = try #require(provider.attachRequests.first)
        provider.nextStatus = .init(state: .prepared, receipt: nil, errorMessage: nil)
        let retrying = Task { @MainActor in await session.retry() }
        try await waitUntil("prepared retry attach", condition: { provider.pendingAttach != nil })
        let retryRequest = try #require(provider.attachRequests.last)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(retryRequest.operationID == firstRequest.operationID)
        #expect(try encoder.encode(retryRequest) == encoder.encode(firstRequest))
        #expect(try encoder.encode(provider.statusRequests[0]) == encoder.encode(firstRequest))

        provider.completeAttach(makeReceipt(for: retryRequest))
        #expect(await retrying.value)
        #expect(provider.attachRequests.count == 2)
        #expect(provider.statusRequests.count == 1)
        #expect(committed == 1)
        #expect(session.pendingOperationID == nil)
    }

    @Test @MainActor
    func committedAcknowledgementKeepsNewFieldAndRowDeletionDrafts() async throws {
        let provider = BoundaryAcknowledgementEditorProvider()
        let editor = ModelEditorSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/tmp/initial-conditions-ack.h5"), section: .boundaryConditions)
        await editor.load(asset, kind: .boundaryCondition)
        #expect(editor.loaded)

        editor.set(BoundaryAcknowledgementEditorProvider.descriptionField, "captured description")
        let projectURL = URL(fileURLWithPath: "/tmp/initial-conditions-ack.ras")
        let projectXML = "<Project><Description>captured</Description></Project>"
        let model = BackendModelProvider.ModelSaveRequest(assetPath: asset.url.path,
            kind: ModelEditorKind.boundaryCondition.rawValue, projectPath: projectURL.path,
            revision: BoundaryAcknowledgementEditorProvider.sourceRevision,
            fields: editor.fields, images: [:], projectXml: projectXML, sourceState: editor.sourceState,
            rows: editor.rows.mapValues { $0.map(BackendModelRow.init) }, samples: [:],
            planTimeWindowEdits: [], geometryTopologyState: nil, geometryMeshState: nil, geometryCulvertState: nil)
        let capture = BoundaryInitialConditionsCapture(id: "ack-capture", projectSessionID: UUID(),
            editorID: editor.id, loadRevision: 1, editRevision: 1, asset: asset,
            projectPath: projectURL.path, projectRevision: "project-revision",
            capturedDocumentXML: projectXML, submittedProjectXML: projectXML,
            projectXmlFingerprint: sha256(Data(projectXML.utf8)), descriptionDraft: "captured",
            model: model, editorFields: editor.fields, editorRows: editor.rows,
            editorImages: editor.images, editorSamples: editor.samples, editorSourceState: editor.sourceState)

        editor.set(BoundaryAcknowledgementEditorProvider.descriptionField, "later description edit")
        editor.rows[BoundaryAcknowledgementEditorProvider.tableID] = []
        #expect(editor.modified)

        let receipt = makeAcknowledgementReceipt(asset: asset, projectURL: projectURL,
            fieldID: BoundaryAcknowledgementEditorProvider.descriptionField,
            row: BoundaryAcknowledgementEditorProvider.savedRow)
        #expect(editor.acknowledgeBoundaryInitialConditions(capture, receipt: receipt))
        #expect(editor.fields[BoundaryAcknowledgementEditorProvider.descriptionField] == "later description edit")
        #expect(editor.rows[BoundaryAcknowledgementEditorProvider.tableID]?.isEmpty == true)
        #expect(editor.modified)
    }

    @Test @MainActor
    func committedLateReceiptAdoptsTheFrozenCaptureAfterTheLiveEditorChanges() async throws {
        let provider = HeldBoundaryInitialConditionsProvider()
        let firstCapture = makeInitialConditionsCapture(id: "capture-before-edit")
        var liveCapture = firstCapture
        var committedCaptureIDs: [String] = []
        var endedOperationIDs: [String] = []
        let session = BoundaryInitialConditionsSession(provider: provider)
        func configure(_ capture: BoundaryInitialConditionsCapture) {
            session.configure(capture: capture, isCurrent: { $0.id == liveCapture.id },
                beginCommit: { _, _ in true }, endCommit: { endedOperationIDs.append($0) },
                commit: { captured, _ in committedCaptureIDs.append(captured.id); return true })
        }
        configure(firstCapture)
        provider.nextInspection = makeInspection(for: .init(model: firstCapture.model,
            projectRevision: firstCapture.projectRevision, resultPath: "/tmp/late-commit-result.h5",
            timestamp: "2026-10-17 00:30", numberCulture: "en-US"))
        #expect(await session.inspect(resultURL: URL(fileURLWithPath: "/tmp/late-commit-result.h5"),
            timestamp: "2026-10-17 00:30", numberCulture: "en-US"))

        let attaching = Task { @MainActor in await session.attach() }
        try await waitUntil("attach request", condition: { provider.pendingAttach != nil })
        let request = try #require(provider.attachRequests.first)
        let secondCapture = makeInitialConditionsCapture(id: "capture-after-edit", revision: 2)
        liveCapture = secondCapture
        configure(secondCapture)
        provider.completeAttach(makeReceipt(for: request))

        #expect(await attaching.value)
        #expect(committedCaptureIDs == [firstCapture.id])
        #expect(endedOperationIDs == [request.operationID])
        #expect(session.pendingOperationID == nil)
        #expect(session.capture?.id == secondCapture.id)
        #expect(session.receipt?.operationID == request.operationID)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_CULVERT_PARTICLE_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func bundledStoreAttachesTheRealResultToTheCapturedBoundaryCondition() async throws {
        let environment = ProcessInfo.processInfo.environment
        let executable = URL(fileURLWithPath: try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        let fixtureDirectory = URL(fileURLWithPath: try #require(environment["HECRAS_CULVERT_PARTICLE_ACCEPTANCE_DIRECTORY"]))
        let workingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("boundary-initial-conditions-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: fixtureDirectory, to: workingRoot)
        defer { try? FileManager.default.removeItem(at: workingRoot) }

        let manifest = try JSONDecoder().decode(InitialConditionsAcceptanceManifest.self,
            from: Data(contentsOf: workingRoot.appendingPathComponent("acceptance.json")))
        let projectURL = workingRoot.appendingPathComponent(manifest.projectRelativePath)
        let boundaryURL = workingRoot.appendingPathComponent(manifest.boundaryConditionRelativePath)
        let result = try #require(manifest.results.first { $0.role == "signed-flow" })
        let resultURL = workingRoot.appendingPathComponent(result.path)
        let originalProjectBytes = try Data(contentsOf: projectURL)
        let originalBoundaryBytes = try Data(contentsOf: boundaryURL)
        let originalResultBytes = try Data(contentsOf: resultURL)
        #expect(sha256(originalResultBytes) == result.revision)

        let client = BackendProcessClient(executableURL: executable)
        let modelProvider = BackendModelProvider(client: client)
        let store = WorkspaceStore(system: SourceWorkflowFixtureServices(
            recoveryFolder: workingRoot.appendingPathComponent("Recovery")),
            modelProvider: modelProvider,
            initialConditionsProvider: BackendBoundaryInitialConditionsProvider(client: client))
        store.requestOpen(projectURL)
        try await waitUntil("source project open", timeout: .seconds(30), condition: {
            store.document?.url?.standardizedFileURL == projectURL.standardizedFileURL && !store.isOpeningProject
        })
        let boundary = try #require(store.assets.first {
            $0.section == .boundaryConditions && $0.url.standardizedFileURL == boundaryURL.standardizedFileURL
        })
        let editor = store.primaryEditorSession(.boundaryCondition)
        await editor.load(boundary, kind: .boundaryCondition)
        #expect(editor.loaded && editor.canEdit && editor.error == nil)
        let descriptionField = try #require(BoundaryFieldReferences.find(suffix: "_Description",
            schemas: ["BoundaryConditionCatalogSummary", "BoundaryConditionsSummary"], values: editor.fields))
        let boundaryDraftDescription = "Saved with initial conditions 中文"
        editor.set(descriptionField.storageID, boundaryDraftDescription)
        #expect(editor.modified)
        store.descriptionDraft = "Unsaved description included in initial-condition attach 中文"
        let originalBoundaryRevision = try #require(editor.sourceFileRevision)
        let workflow = try store.boundaryInitialConditionsSession(for: editor)

        #expect(await workflow.inspect(resultURL: resultURL, timestamp: nil, numberCulture: "en-US"))
        let inspected = try #require(workflow.inspection)
        #expect(inspected.resultRevision == result.revision)
        #expect(inspected.canAttach)
        #expect(await workflow.attach())

        let receipt = try #require(workflow.receipt)
        #expect(receipt.operationID.count > 0)
        #expect(receipt.resultRevision == result.revision)
        #expect(receipt.model.revision != originalBoundaryRevision)
        #expect(receipt.model.fields[descriptionField.storageID] == boundaryDraftDescription)
        #expect(!store.isRunningInitialConditionsCommit)
        #expect(workflow.pendingOperationID == nil)
        #expect(!editor.modified)
        #expect(store.document?.connections.filter { $0.name == receipt.connectionName }.count == 1)
        #expect(try ProjectDocument(contentsOf: projectURL).description
            == "Unsaved description included in initial-condition attach 中文")
        #expect(try Data(contentsOf: projectURL) != originalProjectBytes)
        #expect(try Data(contentsOf: boundaryURL) != originalBoundaryBytes)
        #expect(try Data(contentsOf: resultURL) == originalResultBytes)
        #expect(store.errorMessage == nil)
    }
}

@MainActor
private final class HeldBoundaryInitialConditionsProvider: BoundaryInitialConditionsProvider {
    private(set) var inspectionRequests: [BoundaryInitialConditionsInspectionRequest] = []
    private(set) var attachRequests: [BoundaryInitialConditionsAttachRequest] = []
    private(set) var statusRequests: [BoundaryInitialConditionsAttachRequest] = []
    var nextInspection: BoundaryInitialConditionsInspection?
    var nextAttachError: Error?
    var nextStatus: BoundaryInitialConditionsOperationStatus?
    private(set) var pendingInspection: CheckedContinuation<BoundaryInitialConditionsInspection, Error>?
    private(set) var pendingAttach: CheckedContinuation<BoundaryInitialConditionsReceipt, Error>?

    func inspect(_ request: BoundaryInitialConditionsInspectionRequest) async throws -> BoundaryInitialConditionsInspection {
        inspectionRequests.append(request)
        if let nextInspection { self.nextInspection = nil; return nextInspection }
        return try await withCheckedThrowingContinuation { pendingInspection = $0 }
    }

    func attach(_ request: BoundaryInitialConditionsAttachRequest) async throws -> BoundaryInitialConditionsReceipt {
        attachRequests.append(request)
        if let nextAttachError { self.nextAttachError = nil; throw nextAttachError }
        return try await withCheckedThrowingContinuation { pendingAttach = $0 }
    }

    func status(_ request: BoundaryInitialConditionsAttachRequest) async throws -> BoundaryInitialConditionsOperationStatus {
        statusRequests.append(request)
        guard let nextStatus else { throw InitialConditionsFixtureError.noStatus }
        self.nextStatus = nil
        return nextStatus
    }

    func completeInspection(_ response: BoundaryInitialConditionsInspection) {
        pendingInspection?.resume(returning: response)
        pendingInspection = nil
    }

    func completeAttach(_ receipt: BoundaryInitialConditionsReceipt) {
        pendingAttach?.resume(returning: receipt)
        pendingAttach = nil
    }
}

private enum InitialConditionsFixtureError: Error { case lostResponse, noStatus }

private struct InitialConditionsAcceptanceManifest: Decodable {
    struct Result: Decodable {
        let role: String
        let path: String
        let revision: String
    }
    let projectRelativePath: String
    let boundaryConditionRelativePath: String
    let results: [Result]
}

private func makeInitialConditionsCapture(id: String = "capture-1", revision: Int = 1) -> BoundaryInitialConditionsCapture {
    let projectURL = URL(fileURLWithPath: "/tmp/initial-conditions-project.ras")
    let asset = ProjectAsset(url: URL(fileURLWithPath: "/tmp/initial-conditions-boundary.h5"), section: .boundaryConditions)
    let projectXML = "<Project><Description>draft</Description></Project>"
    let model = BackendModelProvider.ModelSaveRequest(assetPath: asset.url.path,
        kind: ModelEditorKind.boundaryCondition.rawValue, projectPath: projectURL.path,
        revision: "asset-sha-\(revision)", fields: [:], images: [:], projectXml: projectXML,
        sourceState: nil, rows: [:], samples: [:], planTimeWindowEdits: [],
        geometryTopologyState: nil, geometryMeshState: nil, geometryCulvertState: nil)
    let digest = sha256(Data(projectXML.utf8))
    return BoundaryInitialConditionsCapture(id: id, projectSessionID: UUID(), editorID: UUID(),
        loadRevision: 1, editRevision: revision, asset: asset, projectPath: projectURL.path,
        projectRevision: "project-sha", capturedDocumentXML: projectXML,
        submittedProjectXML: projectXML, projectXmlFingerprint: digest, descriptionDraft: "draft",
        model: model, editorFields: [:], editorRows: [:], editorImages: [:], editorSamples: [:], editorSourceState: nil)
}

private func makeInspection(for request: BoundaryInitialConditionsInspectionRequest) -> BoundaryInitialConditionsInspection {
    let projectXML = request.model.projectXml ?? ""
    return .init(assetPath: request.model.assetPath, assetRevision: request.model.revision,
        projectPath: request.model.projectPath ?? "", projectRevision: request.projectRevision,
        projectXmlFingerprint: sha256(Data(projectXML.utf8)), resultPath: request.resultPath,
        resultRevision: "result-sha", timestamp: request.timestamp ?? "", numberCulture: request.numberCulture,
        canAttach: true, errorMessage: nil)
}

private func makeReceipt(for request: BoundaryInitialConditionsAttachRequest,
                         alreadyCommitted: Bool = false) -> BoundaryInitialConditionsReceipt {
    let savedXML = (request.model.projectXml ?? "").replacingOccurrences(of: "draft", with: "committed")
    let model = BackendModelProvider.ModelSnapshot(revision: "new-asset-sha", fields: [:], images: [:],
        canEdit: true, fieldGroups: [:], availableOperations: [], boundary: nil, sourceState: nil,
        readOnlyFields: nil, planTimeWindowFieldIDs: nil, grids: nil, manning: nil,
        classification: nil, terrain: nil, fieldChoices: nil, fieldTitles: nil)
    return .init(operationID: request.operationID, assetPath: request.model.assetPath,
        projectPath: request.model.projectPath ?? "", resultPath: request.resultPath,
        resultRevision: request.resultRevision, projectRevision: sha256(Data(savedXML.utf8)),
        projectXml: savedXML, connectionName: "Attached RAS Result", timestamp: request.timestamp ?? "",
        model: model, alreadyCommitted: alreadyCommitted)
}

@MainActor
private final class BoundaryAcknowledgementEditorProvider: ModelEditorProvider {
    static let descriptionField = "BoundaryAcknowledgementTests/Description"
    static let tableID = "BoundaryAcknowledgementTests/Values"
    static let sourceRevision = "boundary-ack-source-revision"
    static let savedRow = EditorRow(id: "row-1", values: ["Value": "12.5"])

    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot {
        EditorSnapshot(fields: [Self.descriptionField: "source description"],
            rows: [Self.tableID: [Self.savedRow]], samples: [:], canEdit: true, images: [:],
            sourceRevision: Self.sourceRevision)
    }

    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws {}

    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot {
        try await load(asset, kind: .boundaryCondition)
    }
}

@MainActor
private func makeAcknowledgementReceipt(asset: ProjectAsset, projectURL: URL, fieldID: String,
                                        row: EditorRow) -> BoundaryInitialConditionsReceipt {
    let table = BackendBoundaryData.Series(pageId: "ack-series", scope: "ack-scope", schemaId: "ack-schema",
        tableId: BoundaryAcknowledgementEditorProvider.tableID, samples: [],
        rows: [BackendModelRow(row)],
        columns: [.init(id: "Value", title: "Value", sourceType: "double", readOnly: false, width: 120)],
        canEditX: false, xIsDate: false, operations: [], stations: [], xTitle: "Time", yTitle: "Value", valueUnits: nil)
    let boundary = BackendBoundaryData(lines: [], series: [BoundaryAcknowledgementEditorProvider.tableID: table],
        selectedLineId: nil, selectedPayloadId: nil, spatial: nil)
    let model = BackendModelProvider.ModelSnapshot(revision: "boundary-ack-saved-revision",
        fields: [fieldID: "captured description"], images: [:], canEdit: true, fieldGroups: [:],
        availableOperations: [], boundary: boundary, sourceState: nil, readOnlyFields: nil,
        planTimeWindowFieldIDs: nil, grids: nil, manning: nil, classification: nil, terrain: nil, fieldChoices: nil, fieldTitles: nil)
    return BoundaryInitialConditionsReceipt(operationID: "ack-operation", assetPath: asset.url.path,
        projectPath: projectURL.path, resultPath: "/tmp/ack-result.h5", resultRevision: "result-revision",
        projectRevision: "saved-project-revision", projectXml: "<Project />", connectionName: "Result",
        timestamp: "", model: model, alreadyCommitted: false)
}

@MainActor
private func waitUntil(_ label: String, timeout: Duration = .seconds(5),
                       condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    if condition() { return }
    throw InitialConditionsTestError.timedOut(label)
}

private enum InitialConditionsTestError: Error { case timedOut(String) }

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
}
