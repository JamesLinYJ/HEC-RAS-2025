import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class TerrainInputImportProviderFixture: ModelEditorProvider {
    static let sourceField = TerrainEditorContract.sourceField
    static let sourceRevision = "terrain-revision-1"
    static let originalSourceState = "original-terrain-source-state"

    var inspection = TerrainInputImportInspection(
        targetProjection: "EPSG:26910",
        sources: [
            .init(id: "source-a", path: "/imports/a.tif", name: "a.tif", revision: "raster-a-1",
                isValid: true, error: nil, width: 100, height: 80, bandCount: 1, cellSize: 2,
                projection: "EPSG:26910", minimum: 0, maximum: 4, defaultScaleFactor: 1,
                overviewCount: 1, overviews: ["100 × 80"]),
            .init(id: "source-b", path: "/imports/b.tif", name: "b.tif", revision: "raster-b-1",
                isValid: true, error: nil, width: 120, height: 90, bandCount: 1, cellSize: 1,
                projection: "EPSG:26910", minimum: -1, maximum: 7, defaultScaleFactor: 1,
                overviewCount: 1, overviews: ["120 × 90"])
        ],
        roundingOptions: ["None", "Tenths", "Hundredths", "Thousandths", "Sixteenths", "ThirtySeconds",
            "SixtyFourths", "HundredTwentyEighths", "ThousandTwentyFourths"],
        unitConversionOptions: ["Default", "None", "FeetToMeters", "MetersToFeet", "Custom"],
        stitchTilesDefault: true)
    var failedPaths: Set<String> = []
    var loseAppendResponse = false
    var loseAppendResponseOnCall = 1
    var notFoundStatusResponsesRemaining = 0
    var statusRemainsRunningAfterLostAppend = false
    var statusState = "Running"
    var unavailableStatusCode: String?
    var unavailableStatusDiagnostic: String?
    var unavailableStatusOperations: [TerrainInputOperationResult] = []
    var cancelReceipt = TerrainInputImportCancelReceipt(accepted: true, state: "Cancelled", operationID: nil)
    var draftCleanupSucceeds = true
    private(set) var inspectCalls = 0
    private(set) var appendCalls = 0
    private(set) var statusCalls = 0
    private(set) var cancelCalls: [String?] = []
    private(set) var saveCalls = 0
    private(set) var appendedSelections: [TerrainInputImportSelection] = []
    private(set) var appendedStitchTiles: Bool?
    private(set) var appendedDraftToken: String?
    private(set) var appendedBatchToken: String?
    private(set) var appendRequests: [TerrainInputAppendRequest] = []
    private(set) var pendingResult: TerrainInputAppendResult?
    private(set) var statusResult: TerrainInputAppendResult?
    private(set) var discardedTokens: [String] = []
    private(set) var discardedBatchKeys: [String] = []

    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot {
        snapshot(sourceIDs: ["original-input"], sourceState: Self.originalSourceState)
    }

    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws {}
    func saveModel(_ asset: ProjectAsset, changes: EditorEdits) async throws -> EditorSaveResult {
        saveCalls += 1
        let saved = snapshot(sourceIDs: ["original-input"], sourceState: Self.originalSourceState,
            fieldOverrides: changes.fields)
        return EditorSaveResult(sourceRevision: Self.sourceRevision,
            snapshot: saved)
    }
    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot { throw CocoaError(.featureUnsupported) }

    func inspectTerrainInputImport(_ asset: ProjectAsset, edits: EditorEdits, files: [URL]) async throws -> TerrainInputImportInspection {
        inspectCalls += 1
        return inspection
    }

    func makeTerrainInputAppendRequest(_ asset: ProjectAsset, edits: EditorEdits,
                                       selections: [TerrainInputImportSelection], stitchTiles: Bool,
                                       draftToken: String, batchToken: String) throws -> TerrainInputAppendRequest {
        let model = BackendModelProvider.ModelSaveRequest(assetPath: asset.url.path, kind: ModelEditorKind.terrain.rawValue,
            projectPath: nil, revision: Self.sourceRevision, fields: edits.fields,
            images: edits.images.mapValues { $0.map(BackendModelProvider.ImageData.init) }, projectXml: nil,
            sourceState: edits.sourceState, rows: [:], samples: [:], planTimeWindowEdits: [],
            geometryTopologyState: nil, geometryMeshState: nil, geometryCulvertState: nil)
        return TerrainInputAppendRequest(model: model, files: selections, stitchTiles: stitchTiles,
            draftToken: draftToken, batchToken: batchToken)
    }

    func appendTerrainInputImport(_ asset: ProjectAsset, request: TerrainInputAppendRequest) async throws -> TerrainInputAppendResult {
        appendCalls += 1
        appendRequests.append(request)
        appendedSelections = request.files
        appendedStitchTiles = request.stitchTiles
        appendedDraftToken = request.draftToken
        appendedBatchToken = request.batchToken
        let successes = request.files.filter { !failedPaths.contains($0.path) }
        let failures = request.files.filter { failedPaths.contains($0.path) }
        let importedInputIDsByPath = Dictionary(uniqueKeysWithValues: request.files.enumerated().compactMap { index, selection in
            failedPaths.contains(selection.path) ? nil : (selection.path, "imported-\(request.batchToken)-\(index)")
        })
        let operations = request.files.enumerated().map { index, selection in
            let failed = failedPaths.contains(selection.path)
            let importedInputID = importedInputIDsByPath[selection.path]
            return TerrainInputOperationResult(operationID: "operation-\(index)", order: index,
                sourceIDs: [selection.sourceID ?? "source"], sourcePaths: [selection.path],
                sourceRevisions: [selection.sourceRevision], status: failed ? "Failed" : "Staged",
                outputInputID: importedInputID, outputName: importedInputID.map { "\($0).tif" },
                diagnostic: failed ? "Synthetic conversion failure." : nil, progress: 1)
        }
        let state = successes.isEmpty ? "Failed" : (failures.isEmpty ? "Completed" : "Partial")
        let priorSnapshot = pendingResult?.snapshot
        let priorSourceIDs: [String]
        if let priorSnapshot, priorSnapshot.sourceState == request.model.sourceState {
            priorSourceIDs = priorSnapshot.terrain?.inputs.map(\.id) ?? ["original-input"]
        } else {
            priorSourceIDs = ["original-input"]
        }
        let importedSourceIDs = request.files.compactMap { importedInputIDsByPath[$0.path] }
        let resultingSourceState = successes.isEmpty
            ? (request.model.sourceState ?? Self.originalSourceState)
            : "staged-terrain-source-state"
        let result = TerrainInputAppendResult(snapshot: backendSnapshot(
            sourceIDs: priorSourceIDs + importedSourceIDs,
            sourceState: resultingSourceState,
            importDraftToken: request.draftToken), draftToken: request.draftToken, batchToken: request.batchToken,
            mode: request.stitchTiles ? "Stitched" : "Individual", batchStatus: state, operations: operations)
        pendingResult = result
        if loseAppendResponse && appendCalls == loseAppendResponseOnCall {
            if statusRemainsRunningAfterLostAppend { statusResult = nil; statusState = "Running" }
            else { statusResult = result }
            throw ProjectFileError.invalid("The append response was lost.")
        }
        return result
    }

    func terrainInputImportStatus(_ asset: ProjectAsset, request: TerrainInputAppendRequest) async throws -> TerrainInputImportStatus {
        statusCalls += 1
        if notFoundStatusResponsesRemaining > 0 {
            notFoundStatusResponsesRemaining -= 1
            return .init(state: "NotFound", result: nil, operations: [])
        }
        if let unavailableStatusCode {
            return .init(state: statusState, result: nil, operations: unavailableStatusOperations,
                resultUnavailableCode: unavailableStatusCode, diagnostic: unavailableStatusDiagnostic)
        }
        if let statusResult {
            return .init(state: statusResult.batchStatus, result: statusResult, operations: statusResult.operations)
        }
        let operations = request.files.enumerated().map { index, selection in
            TerrainInputOperationResult(operationID: "operation-\(index)", order: index,
                sourceIDs: [selection.sourceID ?? "source"], sourcePaths: [selection.path],
                sourceRevisions: [selection.sourceRevision], status: "Running", outputInputID: nil,
                outputName: nil, diagnostic: nil, progress: nil)
        }
        return .init(state: statusState, result: nil, operations: operations)
    }

    func cancelTerrainInputImport(_ asset: ProjectAsset, request: TerrainInputAppendRequest,
                                  operationID: String?) async throws -> TerrainInputImportCancelReceipt {
        cancelCalls.append(operationID)
        if let pendingResult, loseAppendResponse {
            let operations = pendingResult.operations.map { operation in
                TerrainInputOperationResult(operationID: operation.operationID, order: operation.order,
                    sourceIDs: operation.sourceIDs, sourcePaths: operation.sourcePaths,
                    sourceRevisions: operation.sourceRevisions,
                    status: operation.status == "Staged" ? "Staged" : "Cancelled",
                    outputInputID: operation.outputInputID, outputName: operation.outputName,
                    diagnostic: operation.diagnostic, progress: operation.progress)
            }
            let staged = operations.contains { $0.status == "Staged" }
            statusResult = TerrainInputAppendResult(snapshot: pendingResult.snapshot, draftToken: request.draftToken,
                batchToken: request.batchToken, mode: pendingResult.mode,
                batchStatus: staged ? "CancelledPartial" : "Cancelled", operations: operations)
        }
        return cancelReceipt
    }

    func discardTerrainInputImport(_ asset: ProjectAsset, draftToken: String) async throws -> Bool {
        discardedTokens.append(draftToken)
        return draftCleanupSucceeds
    }

    func discardTerrainInputImportBatch(_ asset: ProjectAsset, draftToken: String, batchToken: String) async throws -> Bool {
        discardedBatchKeys.append(draftToken + "|" + batchToken)
        return true
    }

    func waitForDiscard(timeout: Duration = .seconds(3)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while discardedTokens.isEmpty && discardedBatchKeys.isEmpty && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return !discardedTokens.isEmpty || !discardedBatchKeys.isEmpty
    }

    private func snapshot(sourceIDs: [String], sourceState: String,
                          importDraftToken: String? = nil, fieldOverrides: [String: String] = [:]) -> EditorSnapshot {
        let collection = SourceCollection(
            items: sourceIDs.map { EditorChoice(id: $0, title: $0) },
            sourcePriorityReversed: true, canImport: true, canReorder: true,
            multipleImports: true, canRemove: true, terrainConnected: true)
        var fields = [Self.sourceField: "original-input", "TerrainCatalogSummary/Context_Description": ""]
        for (field, value) in fieldOverrides where fields[field] != nil { fields[field] = value }
        return EditorSnapshot(fields: fields, rows: [:], samples: [:],
            canEdit: true, images: [:], sourceCollections: [Self.sourceField: collection],
            sourceRevision: Self.sourceRevision, sourceState: sourceState,
            terrainInputImportDraftToken: importDraftToken)
    }

    private func backendSnapshot(sourceIDs: [String], sourceState: String,
                                 importDraftToken: String?) -> BackendModelProvider.ModelSnapshot {
        let inputs = sourceIDs.map { id in
            BackendTerrainData.Input(id: id, scope: "TerrainLayersEditor/Inputs/\(id)", name: id,
                type: "Raster", filename: "/fixture/\(id).tif", schema: nil, error: nil)
        }
        return BackendModelProvider.ModelSnapshot(revision: Self.sourceRevision,
            fields: [Self.sourceField: "original-input", "TerrainCatalogSummary/Context_Description": ""],
            images: [:], canEdit: true, fieldGroups: [:], availableOperations: [], boundary: nil,
            sourceState: sourceState, readOnlyFields: nil, planTimeWindowFieldIDs: nil,
            grids: nil, manning: nil, classification: nil,
            terrain: BackendTerrainData(inputs: inputs, selectedId: sourceIDs.last,
                importDraftToken: importDraftToken, importCleanupWarning: nil, importCleanupToken: nil),
            fieldChoices: nil, fieldTitles: nil)
    }
}

struct TerrainInputImportSessionTests {
    private let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/Terrains/terrain.h5"), section: .terrains)

    @Test @MainActor
    func statusRecoveryEncodesTheOriginalRequestEnvelopeAndSourceIDField() async throws {
        let provider = TerrainInputImportProviderFixture()
        let selection = TerrainInputImportSelection(path: "/imports/a.tif", sourceRevision: "raster-a-1",
            rounding: "None", unitConversion: "Default", customScaleFactor: nil, sourceID: "source-a")
        let request = try provider.makeTerrainInputAppendRequest(asset,
            edits: EditorEdits(fields: [:], rows: [:], images: [:]), selections: [selection],
            stitchTiles: false, draftToken: String(repeating: "a", count: 32),
            batchToken: String(repeating: "b", count: 32))
        let encoded = try JSONEncoder().encode(TerrainInputImportStatusRequest(request: request))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let nested = try #require(object["request"] as? [String: Any])
        let files = try #require(nested["files"] as? [[String: Any]])
        #expect(files.first?["sourceId"] as? String == "source-a")
        #expect(files.first?["sourceID"] == nil)
        #expect(nested["draftToken"] as? String == String(repeating: "a", count: 32))
        #expect(nested["batchToken"] as? String == String(repeating: "b", count: 32))
    }

    @Test @MainActor
    func inspectionAndAppendStageMultipleSelectedRastersWithoutSavingTheSource() async throws {
        let provider = TerrainInputImportProviderFixture()
        let session = ModelEditorSession(provider: provider)
        await session.load(asset, kind: .terrain)
        let originalSourceState = session.sourceState
        let files = [URL(fileURLWithPath: "/imports/a.tif"), URL(fileURLWithPath: "/imports/b.tif")]
        let identity = session.terrainInputImportIdentity

        let inspection = try await session.inspectTerrainInputImport(files: files, expectedIdentity: identity)
        #expect(provider.inspectCalls == 1)
        #expect(!session.modified)
        #expect(session.sourceState == originalSourceState)
        #expect(session.sourceFileRevision == TerrainInputImportProviderFixture.sourceRevision)

        let selections = [
            TerrainInputImportSelection(path: "/imports/a.tif", sourceRevision: "raster-a-1",
                rounding: "Tenths", unitConversion: "Default", customScaleFactor: nil),
            TerrainInputImportSelection(path: "/imports/b.tif", sourceRevision: "raster-b-1",
                rounding: "None", unitConversion: "Custom", customScaleFactor: 1.25)
        ]
        let appended = await session.appendTerrainInputImport(selections, inspection: inspection,
            stitchTiles: true, expectedIdentity: identity)
        #expect(appended?.batchStatus == "Completed")
        #expect(provider.appendCalls == 1)
        #expect(provider.appendedSelections.map(\.path) == selections.map(\.path))
        #expect(provider.appendedSelections.allSatisfy { $0.sourceID != nil })
        #expect(provider.appendedStitchTiles == true)
        #expect(provider.appendedDraftToken?.isEmpty == false)
        #expect(provider.appendedBatchToken?.isEmpty == false)
        #expect(provider.appendedDraftToken?.count == 32)
        #expect(provider.appendedBatchToken?.count == 32)
        #expect(provider.appendedDraftToken?.allSatisfy(\.isHexDigit) == true)
        #expect(provider.appendedBatchToken?.allSatisfy(\.isHexDigit) == true)
        #expect(session.modified)
        #expect(session.sourceState == "staged-terrain-source-state")
        #expect(session.terrainInputImportDraftToken == provider.appendedDraftToken)
        #expect(session.sourceCollections[TerrainEditorContract.sourceField]?.items.count == 3)

        session.discardEdits()
        #expect(await provider.waitForDiscard())
        #expect(!session.modified)
        #expect(session.sourceState == originalSourceState)
        #expect(session.terrainInputImportDraftToken == nil)
        #expect(session.sourceCollections[TerrainEditorContract.sourceField]?.items.count == 1)
        #expect(provider.discardedTokens == [provider.appendedDraftToken].compactMap { $0 })
    }

    @Test @MainActor
    func staleTerrainOwnerCannotInspectOrAppend() async {
        let provider = TerrainInputImportProviderFixture()
        let session = ModelEditorSession(provider: provider)
        await session.load(asset, kind: .terrain)
        let capturedIdentity = session.terrainInputImportIdentity
        let inspection = provider.inspection
        session.fields[TerrainInputImportProviderFixture.sourceField] = "another-source"

        var inspectionReturned = false
        do {
            _ = try await session.inspectTerrainInputImport(files: [URL(fileURLWithPath: "/imports/a.tif")],
                expectedIdentity: capturedIdentity)
            inspectionReturned = true
        } catch {}
        #expect(!inspectionReturned)
        let staleAppend = await session.appendTerrainInputImport([
            TerrainInputImportSelection(path: "/imports/a.tif", sourceRevision: "raster-a-1",
                rounding: "None", unitConversion: "Default", customScaleFactor: nil)
        ], inspection: inspection, stitchTiles: false, expectedIdentity: capturedIdentity)
        #expect(staleAppend == nil)
        #expect(provider.inspectCalls == 0)
        #expect(provider.appendCalls == 0)
        #expect(!session.modified)
    }

    @Test @MainActor
    func failedFirstBatchKeepsFailuresVisibleWithoutStagingThem() async throws {
        let provider = TerrainInputImportProviderFixture()
        provider.failedPaths.insert("/imports/a.tif")
        let session = ModelEditorSession(provider: provider)
        await session.load(asset, kind: .terrain)
        let originalSourceState = session.sourceState
        let identity = session.terrainInputImportIdentity
        let inspection = try await session.inspectTerrainInputImport(
            files: [URL(fileURLWithPath: "/imports/a.tif")], expectedIdentity: identity)
        let selection = TerrainInputImportSelection(path: "/imports/a.tif", sourceRevision: "raster-a-1",
            rounding: "None", unitConversion: "Default", customScaleFactor: nil)

        let appended = await session.appendTerrainInputImport([selection], inspection: inspection,
            stitchTiles: false, expectedIdentity: identity)
        #expect(appended?.batchStatus == "Failed")
        #expect(appended?.failedOperations.first?.diagnostic == "Synthetic conversion failure.")
        #expect(provider.appendCalls == 1)
        #expect(provider.discardedTokens.isEmpty)
        #expect(provider.discardedBatchKeys.isEmpty)
        #expect(!session.modified)
        #expect(session.sourceState == originalSourceState)
        #expect(session.terrainInputImportDraftToken == provider.appendedDraftToken)
        #expect(session.sourceCollections[TerrainEditorContract.sourceField]?.items.count == 1)
        #expect(session.error == nil)
    }

    @Test @MainActor
    func failedLaterBatchRemovesOnlyThatBatchAndKeepsPreviouslyStagedRasters() async throws {
        let provider = TerrainInputImportProviderFixture()
        let session = ModelEditorSession(provider: provider)
        await session.load(asset, kind: .terrain)
        let originalIdentity = session.terrainInputImportIdentity
        let inspection = try await session.inspectTerrainInputImport(
            files: [URL(fileURLWithPath: "/imports/a.tif"), URL(fileURLWithPath: "/imports/b.tif")],
            expectedIdentity: originalIdentity)
        let first = TerrainInputImportSelection(path: "/imports/a.tif", sourceRevision: "raster-a-1",
            rounding: "None", unitConversion: "Default", customScaleFactor: nil)
        #expect((await session.appendTerrainInputImport([first], inspection: inspection,
            stitchTiles: false, expectedIdentity: originalIdentity))?.batchStatus == "Completed")
        let acceptedDraftToken = try #require(session.terrainInputImportDraftToken)
        let acceptedSourceState = session.sourceState
        provider.failedPaths.insert("/imports/b.tif")
        let second = TerrainInputImportSelection(path: "/imports/b.tif", sourceRevision: "raster-b-1",
            rounding: "None", unitConversion: "Default", customScaleFactor: nil)

        let appended = await session.appendTerrainInputImport([second], inspection: inspection,
            stitchTiles: false, expectedIdentity: session.terrainInputImportIdentity)
        #expect(appended?.batchStatus == "Failed")
        #expect(provider.discardedTokens.isEmpty)
        #expect(provider.discardedBatchKeys.isEmpty)
        #expect(session.terrainInputImportDraftToken == acceptedDraftToken)
        #expect(session.sourceState == acceptedSourceState)
        #expect(session.sourceCollections[TerrainEditorContract.sourceField]?.items.count == 2)
        #expect(session.modified)
    }

    @Test @MainActor
    func lostAppendResponseRecoversCommittedResultByExactStatusRequest() async throws {
        let provider = TerrainInputImportProviderFixture()
        provider.loseAppendResponse = true
        let session = ModelEditorSession(provider: provider)
        await session.load(asset, kind: .terrain)
        let identity = session.terrainInputImportIdentity
        let inspection = try await session.inspectTerrainInputImport(
            files: [URL(fileURLWithPath: "/imports/a.tif")], expectedIdentity: identity)
        let selection = TerrainInputImportSelection(path: "/imports/a.tif", sourceRevision: "raster-a-1",
            rounding: "None", unitConversion: "Default", customScaleFactor: nil)

        let result = await session.appendTerrainInputImport([selection], inspection: inspection,
            stitchTiles: false, expectedIdentity: identity)
        #expect(result?.batchStatus == "Completed")
        #expect(provider.statusCalls == 1)
        #expect(provider.discardedTokens.isEmpty)
        #expect(provider.discardedBatchKeys.isEmpty)
        #expect(session.modified)
        #expect(session.sourceState == "staged-terrain-source-state")
        #expect(session.sourceCollections[TerrainEditorContract.sourceField]?.items.count == 2)
        #expect(provider.inspection.sources[0].id == provider.appendedSelections.first?.sourceID)
    }

    @Test @MainActor
    func boundedNotFoundPollsReplayIdenticalIdempotentAppendRequest() async throws {
        let provider = TerrainInputImportProviderFixture()
        provider.loseAppendResponse = true
        provider.notFoundStatusResponsesRemaining = 3
        let session = ModelEditorSession(provider: provider)
        await session.load(asset, kind: .terrain)
        let identity = session.terrainInputImportIdentity
        let inspection = try await session.inspectTerrainInputImport(
            files: [URL(fileURLWithPath: "/imports/a.tif")], expectedIdentity: identity)
        let selection = TerrainInputImportSelection(path: "/imports/a.tif", sourceRevision: "raster-a-1",
            rounding: "None", unitConversion: "Default", customScaleFactor: nil)

        let result = await session.appendTerrainInputImport([selection], inspection: inspection,
            stitchTiles: false, expectedIdentity: identity)
        #expect(result?.batchStatus == "Completed")
        #expect(provider.statusCalls == 3)
        #expect(provider.appendRequests.count == 2)
        #expect(provider.appendRequests[0].draftToken == provider.appendRequests[1].draftToken)
        #expect(provider.appendRequests[0].batchToken == provider.appendRequests[1].batchToken)
        #expect(provider.appendRequests[0].files == provider.appendRequests[1].files)
        #expect(provider.discardedTokens.isEmpty && provider.discardedBatchKeys.isEmpty)
        #expect(session.sourceCollections[TerrainEditorContract.sourceField]?.items.count == 2)
    }

    @Test @MainActor
    func cancelAndStatusRecoveryPreserveAlreadyStagedOperations() async throws {
        let provider = TerrainInputImportProviderFixture()
        provider.loseAppendResponse = true
        provider.statusRemainsRunningAfterLostAppend = true
        provider.failedPaths.insert("/imports/b.tif")
        let session = ModelEditorSession(provider: provider)
        await session.load(asset, kind: .terrain)
        let identity = session.terrainInputImportIdentity
        let inspection = try await session.inspectTerrainInputImport(
            files: [URL(fileURLWithPath: "/imports/a.tif"), URL(fileURLWithPath: "/imports/b.tif")],
            expectedIdentity: identity)
        let selections = inspection.sources.map {
            TerrainInputImportSelection(path: $0.path, sourceRevision: $0.revision,
                rounding: "None", unitConversion: "Default", customScaleFactor: nil, sourceID: $0.id)
        }

        let lostResponse = await session.appendTerrainInputImport(selections, inspection: inspection,
            stitchTiles: false, expectedIdentity: identity)
        #expect(lostResponse == nil)
        #expect(session.isTerrainInputImportRunning)
        #expect(session.sourceCollections[TerrainEditorContract.sourceField]?.items.count == 1)
        #expect(provider.discardedTokens.isEmpty && provider.discardedBatchKeys.isEmpty)

        #expect(await session.cancelTerrainInputImport(expectedIdentity: identity, operationID: "operation-1"))
        #expect(provider.cancelCalls == ["operation-1"])
        let recovered = await session.refreshTerrainInputImportStatus(expectedIdentity: identity)
        #expect(recovered?.batchStatus == "CancelledPartial")
        #expect(recovered?.hasStagedOutputs == true)
        #expect(recovered?.failedOperations.first?.status == "Cancelled")
        #expect(!session.isTerrainInputImportRunning)
        #expect(session.modified)
        #expect(session.sourceState == "staged-terrain-source-state")
        #expect(session.sourceCollections[TerrainEditorContract.sourceField]?.items.count == 2)
        #expect(provider.discardedTokens.isEmpty && provider.discardedBatchKeys.isEmpty)
    }

    @Test @MainActor
    func sourceChangedTerminalStatusRetainsOperationResultsWithoutInstallingSnapshot() async throws {
        let provider = TerrainInputImportProviderFixture()
        provider.statusState = "Partial"
        provider.unavailableStatusCode = "sourceChanged"
        provider.unavailableStatusDiagnostic = "The terrain source changed after conversion."
        let unresolvedOperation = TerrainInputOperationResult(operationID: "operation-1", order: 0,
            sourceIDs: ["source-b"], sourcePaths: ["/imports/b.tif"], sourceRevisions: ["raster-b-1"],
            status: "Staged", outputInputID: "pending-b", outputName: "pending-b.tif",
            diagnostic: nil, progress: 1)
        provider.unavailableStatusOperations = [unresolvedOperation]

        let session = ModelEditorSession(provider: provider)
        await session.load(asset, kind: .terrain)
        let identity = session.terrainInputImportIdentity
        let inspection = try await session.inspectTerrainInputImport(
            files: [URL(fileURLWithPath: "/imports/a.tif"), URL(fileURLWithPath: "/imports/b.tif")],
            expectedIdentity: identity)
        let acceptedSelection = TerrainInputImportSelection(path: "/imports/a.tif", sourceRevision: "raster-a-1",
            rounding: "None", unitConversion: "Default", customScaleFactor: nil, sourceID: "source-a")
        let accepted = await session.appendTerrainInputImport([acceptedSelection], inspection: inspection,
            stitchTiles: false, expectedIdentity: identity)
        #expect(accepted?.batchStatus == "Completed")
        let acceptedDraftToken = try #require(session.terrainInputImportDraftToken)
        let acceptedSourceState = session.sourceState

        provider.loseAppendResponse = true
        provider.loseAppendResponseOnCall = 2
        let selection = TerrainInputImportSelection(path: "/imports/b.tif", sourceRevision: "raster-b-1",
            rounding: "None", unitConversion: "Default", customScaleFactor: nil, sourceID: "source-b")

        let result = await session.appendTerrainInputImport([selection], inspection: inspection,
            stitchTiles: false, expectedIdentity: session.terrainInputImportIdentity)
        #expect(result == nil)
        #expect(!session.isTerrainInputImportRunning)
        #expect(!session.isBusy)
        #expect(session.terrainInputImportStatus?.resultUnavailableCode == "sourceChanged")
        #expect(session.terrainInputImportStatus?.operations == [unresolvedOperation])
        #expect(session.canRecheckTerrainInputImportStatus)
        #expect(session.terrainInputImportCleanupToken == provider.appendedDraftToken)
        #expect(session.terrainInputImportCleanupBatchToken == provider.appendedBatchToken)
        #expect(session.terrainInputImportDraftToken == acceptedDraftToken)
        #expect(session.sourceState == acceptedSourceState)
        #expect(session.sourceCollections[TerrainEditorContract.sourceField]?.items.count == 2)
        #expect(provider.discardedTokens.isEmpty && provider.discardedBatchKeys.isEmpty)

        #expect(!(await session.saveLoadedModel()))
        #expect(provider.saveCalls == 0)
        #expect(session.modified)

        let recovered = await session.refreshTerrainInputImportStatus(expectedIdentity: session.terrainInputImportIdentity)
        #expect(recovered == nil)
        #expect(provider.statusCalls == 2)
        #expect(!session.isTerrainInputImportRunning && !session.isBusy)
        #expect(session.terrainInputImportStatus?.operations == [unresolvedOperation])

        #expect(await session.retryTerrainInputImportCleanup())
        #expect(provider.discardedBatchKeys == ["\(provider.appendedDraftToken!)|\(provider.appendedBatchToken!)"])
        #expect(session.terrainInputImportCleanupToken == nil)
        #expect(!session.canRecheckTerrainInputImportStatus)
        #expect(session.sourceState == acceptedSourceState)
        #expect(session.terrainInputImportDraftToken == acceptedDraftToken)
        #expect(session.sourceCollections[TerrainEditorContract.sourceField]?.items.count == 2)
        #expect(session.modified)
    }

    @Test @MainActor
    func explicitStatusRecheckInstallsRecoveredSnapshotAfterSourcesAreRestored() async throws {
        let provider = TerrainInputImportProviderFixture()
        provider.loseAppendResponse = true
        provider.unavailableStatusCode = "sourceChanged"
        provider.statusState = "Completed"
        provider.unavailableStatusOperations = [TerrainInputOperationResult(operationID: "operation-0", order: 0,
            sourceIDs: ["source-a"], sourcePaths: ["/imports/a.tif"], sourceRevisions: ["raster-a-1"],
            status: "Staged", outputInputID: "imported-0", outputName: "imported-0.tif",
            diagnostic: nil, progress: 1)]
        let session = ModelEditorSession(provider: provider)
        await session.load(asset, kind: .terrain)
        let identity = session.terrainInputImportIdentity
        let inspection = try await session.inspectTerrainInputImport(
            files: [URL(fileURLWithPath: "/imports/a.tif")], expectedIdentity: identity)
        let selection = TerrainInputImportSelection(path: "/imports/a.tif", sourceRevision: "raster-a-1",
            rounding: "None", unitConversion: "Default", customScaleFactor: nil, sourceID: "source-a")

        #expect(await session.appendTerrainInputImport([selection], inspection: inspection,
            stitchTiles: false, expectedIdentity: identity) == nil)
        #expect(session.canRecheckTerrainInputImportStatus)
        let draftToken = try #require(provider.appendedDraftToken)
        provider.unavailableStatusCode = nil

        let recovered = await session.refreshTerrainInputImportStatus(expectedIdentity: identity)
        #expect(recovered?.batchStatus == "Completed")
        #expect(!session.isTerrainInputImportRunning && !session.isBusy)
        #expect(session.terrainInputImportCleanupToken == nil)
        #expect(session.terrainInputImportCleanupBatchToken == nil)
        #expect(!session.canRecheckTerrainInputImportStatus)
        #expect(session.terrainInputImportDraftToken == draftToken)
        #expect(session.sourceState == "staged-terrain-source-state")
        #expect(session.sourceCollections[TerrainEditorContract.sourceField]?.items.count == 2)
        #expect(provider.discardedTokens.isEmpty && provider.discardedBatchKeys.isEmpty)
    }
}
