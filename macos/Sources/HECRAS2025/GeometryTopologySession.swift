import Foundation
import RASWorkspaceCore
import SwiftUI

struct GeometryTopologyParentSaveCapture: Sendable {
    let operationID: UUID
    let generation: Int
    let assetID: String?
    let draftState: String?
    let sourceRevision: String?
}

private struct GeometryTopologyDraftPayload: Codable, Sendable {
    let assetPath: String
    let revision: String
    let mutations: [GeometryTopologyMutation]
    let redoMutations: [GeometryTopologyMutation]
    let recentArcTags: [GeometryTopologyRecentTag]
    let recentRegionTags: [GeometryTopologyRecentTag]
}

private struct GeometryTopologyToolRequestCapture: Sendable {
    let model: GeometryTopologyModelRequest
    let assetID: String
    let sourceRevision: String
    let draftState: String
    let draftIdentity: String
    let modelGeneration: Int
    let loadGeneration: Int
}

private struct PendingGeometryRegionInputWrite {
    let loadGeneration: Int
    let modelGeneration: Int
    let assetID: String
    let model: GeometryTopologyModelRequest
    let sourceRevision: String
    let rowIDs: [String]
    let fieldID: String
    let value: String
    let completion: @MainActor (Bool) -> Void
}

/// Owns the geometry topology child draft while ModelEditorSession owns the
/// surrounding geometry fields and images. The parent submits this opaque
/// state as part of the same model.save request.
@MainActor
final class GeometryTopologySession: ObservableObject {
    private let provider: any GeometryTopologyProvider
    var onParentDraftChange: @MainActor (Bool) -> Void = { _ in }
    private var currentAsset: ProjectAsset?
    private var currentModel: GeometryTopologyModelRequest?
    private var expectedSourceRevision: String?
    private var didLoad = false
    private var loadGeneration = 0
    private var modelGeneration = 0
    private var activeParentSaveID: UUID?

    @Published private(set) var snapshot: GeometryTopologySnapshot?
    @Published private(set) var selectedFeatureIDs: [String: Set<String>] = ["arc": [], "region": [], "node": []]
    @Published private(set) var selectedDiagnosticMessageID: String?
    @Published private(set) var selectedDiagnosticTargets: [GeometryTopologyDiagnosticTarget] = []
    @Published private(set) var diagnosticMapFeatureIDs: Set<String> = []
    @Published private(set) var isLoading = false
    @Published private(set) var isEditing = false
    @Published private(set) var parentSaveInProgress = false
    @Published var error: String?

    @Published private(set) var arcPoints: GeometryTopologyArcPointsSnapshot?
    @Published private(set) var isLoadingArcPoints = false
    @Published private(set) var arcPointsError: String?
    @Published private(set) var recipeEditorState: GeometryTopologyRecipeEditorState?
    @Published private(set) var tagFilterQueries: [String: GeometryTopologyTagFilterQuery] = [
        "arc": GeometryTopologyTagFilterQuery(featureKind: "arc"),
        "region": GeometryTopologyTagFilterQuery(featureKind: "region")
    ]
    @Published private(set) var tagFilterResults: [String: GeometryTopologyFilterSnapshot] = [:]
    @Published private(set) var tagFilterLoadingKinds: Set<String> = []
    @Published private(set) var tagFilterErrors: [String: String] = [:]
    @Published private(set) var activeTagFilterFeatureKind = "arc"

    private var arcPointsGeneration = 0
    private var recipeInspectionGeneration = 0
    private var recipeInputGeneration = 0
    private var tagFilterGeneration: [String: Int] = [:]
    private var tagFilterQueryGeneration: [String: Int] = ["arc": 0, "region": 0]
    private var tagFilterResultQueryGeneration: [String: Int] = [:]
    private var pendingArcPointInputOrder: [String] = []
    private var pendingArcPointInputs: [String: GeometryTopologyArcPointInputDraft] = [:]
    private var pendingRegionInputWrites: [PendingGeometryRegionInputWrite] = []
    private var regionInputWriteWorker: Task<Void, Never>?
    private var regionInputWriteWorkerID: UUID?

    init(provider: any GeometryTopologyProvider,
         onParentDraftChange: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.provider = provider
        self.onParentDraftChange = onParentDraftChange
    }

    var canEdit: Bool { snapshot?.canEdit == true && !parentSaveInProgress }
    var isDirty: Bool { snapshot?.isDirty == true }
    var hasPendingInputs: Bool {
        recipeEditorState?.isPending == true || !pendingArcPointInputs.isEmpty
            || !pendingRegionInputWrites.isEmpty || regionInputWriteWorker != nil
    }
    var isWritingRegionInputs: Bool {
        !pendingRegionInputWrites.isEmpty || regionInputWriteWorker != nil
    }
    var pendingInputIssue: String? {
        if regionInputWriteWorker != nil || !pendingRegionInputWrites.isEmpty {
            return "Wait for the Conceptual Mesh text edits to finish before saving."
        }
        return hasPendingInputs ? "Apply or discard the pending topology input before saving." : nil
    }
    var canMutateTopology: Bool { canEdit && !isEditing && !hasPendingInputs }
    var canBeginParentSave: Bool { !isLoading && !isEditing && !parentSaveInProgress && !hasPendingInputs }
    var canUndo: Bool { snapshot?.canUndo == true && canMutateTopology }
    var canRedo: Bool { snapshot?.canRedo == true && canMutateTopology }
    var topologyStateForParentSave: String? { isDirty ? snapshot?.draftState : nil }
    var mapCameraIdentity: String? { currentAsset?.id }
    var mapAssetIdentity: String? { currentAsset?.id }
    var pendingArcPointInput: GeometryTopologyArcPointInputDraft? {
        pendingArcPointInputOrder.compactMap { pendingArcPointInputs[$0] }.first
    }
    var tagFilterQuery: GeometryTopologyTagFilterQuery { tagFilterQuery(for: activeTagFilterFeatureKind) }
    var tagFilterResult: GeometryTopologyFilterSnapshot? { tagFilterResult(for: activeTagFilterFeatureKind) }
    var tagFilterIsLoading: Bool { tagFilterLoadingKinds.contains(activeTagFilterFeatureKind) }
    var tagFilterError: String? { tagFilterErrors[activeTagFilterFeatureKind] }
    var tagFilterResultIsCurrent: Bool { tagFilterResultIsCurrent(for: activeTagFilterFeatureKind) }

    var buildResultPresentation: TopologyBuildResultPresentation? {
        guard let snapshot, let completion = snapshot.completion,
              completion.sourceRevision == snapshot.revision,
              completion.draftIdentity == GeometryTopologyCompletionResult.draftIdentity(for: snapshot.draftState) else {
            return nil
        }
        return TopologyBuildResultPresentation(sourceRevision: completion.sourceRevision,
            draftIdentity: completion.draftIdentity, succeeded: completion.isComplete,
            messages: completion.messages.map(\.presentation))
    }

    /// Invalidates all in-flight child work. Parent calls this before loading
    /// a different model or starting a fresh editor draft.
    func invalidate() {
        loadGeneration += 1
        modelGeneration += 1
        let hadDraft = isDirty
        currentAsset = nil
        currentModel = nil
        expectedSourceRevision = nil
        didLoad = false
        activeParentSaveID = nil
        snapshot = nil
        selectedFeatureIDs = ["arc": [], "region": [], "node": []]
        clearDiagnosticFocus()
        isLoading = false
        isEditing = false
        parentSaveInProgress = false
        error = nil
        clearTopologyToolState()
        let abandonedRegionWrites = pendingRegionInputWrites
        pendingRegionInputWrites.removeAll()
        for write in abandonedRegionWrites { write.completion(false) }
        regionInputWriteWorker?.cancel()
        regionInputWriteWorker = nil
        regionInputWriteWorkerID = nil
        if hadDraft { onParentDraftChange(false) }
    }

    func ensureLoaded(asset: ProjectAsset, sourceRevision: String?) async {
        guard !parentSaveInProgress else { return }
        guard asset.section == .geometries else {
            error = "Topology editing requires a geometry asset."
            return
        }
        let model = provider.modelRequest(for: asset)
        let sameSource = currentAsset?.id == asset.id && currentModel == model
        if currentAsset != nil && !sameSource {
            if isDirty || hasPendingInputs {
                error = "The geometry changed while topology edits are pending. Discard the topology draft before switching assets."
                return
            }
            invalidate()
        }
        if didLoad, sameSource, expectedSourceRevision == sourceRevision { return }
        if (isDirty || hasPendingInputs) && expectedSourceRevision != sourceRevision {
            error = "The geometry source changed while topology edits are pending. Save or discard the topology draft before reloading."
            return
        }
        currentAsset = asset
        currentModel = model
        expectedSourceRevision = sourceRevision
        await reload(expectedRevision: sourceRevision)
    }

    func reload() async {
        guard !hasPendingInputs else {
            error = pendingInputIssue
            return
        }
        await reload(expectedRevision: expectedSourceRevision)
    }

    func select(_ ids: Set<String>, featureKind: String) {
        guard ["arc", "region", "node"].contains(featureKind) else { return }
        selectedFeatureIDs[featureKind] = ids
    }

    /// Applies the source DataGrid's Delete Selected action to all three
    /// retained topology selections. The source operation deliberately handles
    /// control points, arcs and nodes as one undoable edit because deleting a
    /// control point can also remove arcs/nodes and shift collection indices.
    @discardableResult
    func deleteSelectedFeatures() async -> Bool {
        guard canMutateTopology, let capture = toolRequestCapture() else { return false }
        func selectedFIDs(_ featureKind: String) -> [Int]? {
            let ids = selectedFeatureIDs[featureKind, default: []]
            guard !ids.isEmpty else { return [] }
            return sourceOrderedFeatureIDs(Array(ids), featureKind: featureKind)
        }
        guard let arcFIDs = selectedFIDs("arc"),
              let controlPointFIDs = selectedFIDs("region"),
              let nodeFIDs = selectedFIDs("node"),
              !arcFIDs.isEmpty || !controlPointFIDs.isEmpty || !nodeFIDs.isEmpty,
              toolCaptureIsCurrent(capture) else { return false }
        let mutation = GeometryTopologyMutation(operation: "deleteSelection", featureKind: "selection",
            featureIDs: [], arcFeatureIDs: arcFIDs, controlPointFeatureIDs: controlPointFIDs,
            nodeFeatureIDs: nodeFIDs)
        guard await submit(mutation) else { return false }
        selectedFeatureIDs = ["arc": [], "region": [], "node": []]
        return true
    }

    /// Returns the source outer-ring coordinate sequence for a Region table
    /// row (a control-point FID), matching CopyOuterRegionCoordinates' actual
    /// containing-region lookup rather than copying the point coordinates.
    func outerRegionCoordinates(rowID: String) -> String? {
        guard let snapshot, let row = table(for: "region").rows.first(where: { $0.id == rowID }),
              let feature = snapshot.map?.features.first(where: {
                  $0.featureKind == "region" && $0.geometryType == "polygon"
                      && $0.selectionIDs.contains(row.id)
              }),
              let outerRing = feature.paths.first, outerRing.count >= 3,
              outerRing.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        // Source CopyOuterRegionCoordinates appends one space after every
        // coordinate pair and uses general-number formatting for each Double.
        return outerRing.map { "\(sourceCoordinateText($0.x)),\(sourceCoordinateText($0.y)) " }.joined()
    }

    private func sourceCoordinateText(_ value: Double) -> String {
        let text = String(value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    func selectDiagnosticMessage(_ id: String?) {
        guard let id, let message = snapshot?.completion?.messages.first(where: { $0.id == id }),
              buildResultPresentation != nil else {
            clearDiagnosticFocus()
            return
        }
        selectedDiagnosticMessageID = message.id
        selectedDiagnosticTargets = message.targets
        diagnosticMapFeatureIDs = Set(message.targets.flatMap(\.mapFeatureIDs))
    }

    func canOpenDiagnosticTarget(_ target: GeometryTopologyDiagnosticTarget) -> Bool {
        guard let featureKind = target.tableFeatureKind else { return false }
        return table(for: featureKind).rows.contains { $0.id == target.tableRowID && $0.fid == target.fid }
    }

    /// Opens only a Host-mapped table row. Diagnostic map highlighting remains
    /// a separate overlay, while this action uses normal table selection.
    func openDiagnosticTarget(_ target: GeometryTopologyDiagnosticTarget) -> String? {
        guard canOpenDiagnosticTarget(target), let featureKind = target.tableFeatureKind,
              let pageTitle = target.pageTitle else { return nil }
        select([target.tableRowID], featureKind: featureKind)
        return pageTitle
    }

    func diagnosticMessages(featureKind: String, rowIDs: Set<String>) -> [TopologyBuildMessagePresentation] {
        guard !rowIDs.isEmpty, let result = buildResultPresentation else { return [] }
        return result.messages.filter { message in
            message.targets.contains { target in
                target.tableFeatureKind == featureKind && rowIDs.contains(target.tableRowID)
            }
        }
    }

    func selectedRows(for featureKind: String) -> [GeometryTopologyFeatureRow] {
        let ids = selectedFeatureIDs[featureKind, default: []]
        return table(for: featureKind).rows.filter { ids.contains($0.id) }
    }

    func diagnosticRowIDs(for featureKind: String) -> Set<String> {
        Set(selectedDiagnosticTargets.compactMap { target in
            target.tableFeatureKind == featureKind ? target.tableRowID : nil
        })
    }

    func table(for featureKind: String) -> GeometryTopologyFeatureTable {
        let table: GeometryTopologyFeatureTable?
        switch featureKind {
        case "arc": table = snapshot?.arcs
        case "region": table = snapshot?.regions
        case "node": table = snapshot?.nodes
        default: table = nil
        }
        return table ?? GeometryTopologyFeatureTable(featureKind: featureKind, columns: [], editableFields: [], rows: [])
    }

    func tagDefinitions(for featureKind: String) -> [GeometryTopologyTagDefinition] {
        switch featureKind {
        case "arc": snapshot?.arcTags ?? []
        case "region": snapshot?.regionTags ?? []
        default: []
        }
    }

    func recentTags(for featureKind: String) -> [GeometryTopologyRecentTag] {
        switch featureKind {
        case "arc": snapshot?.recentArcTags ?? []
        case "region": snapshot?.recentRegionTags ?? []
        default: []
        }
    }

    func applyFactor(factorText: String, selectedOnly: Bool) async {
        guard canMutateTopology, !factorText.isEmpty else { return }
        let arcFIDs = selectedOnly ? selectedRows(for: "arc").map(\.fid) : []
        let controlPointFIDs = selectedOnly ? selectedRows(for: "region").map(\.fid) : []
        guard !selectedOnly || !arcFIDs.isEmpty || !controlPointFIDs.isEmpty else { return }
        let mutation = GeometryTopologyMutation(operation: "applyFactor", featureKind: "topology", featureIDs: [],
            applyToSelectedOnly: selectedOnly, factorText: factorText,
            arcFeatureIDs: arcFIDs, controlPointFeatureIDs: controlPointFIDs)
        _ = await submit(mutation)
    }

    func tagFilterQuery(for featureKind: String) -> GeometryTopologyTagFilterQuery {
        let kind = normalizedFilterFeatureKind(featureKind)
        return tagFilterQueries[kind] ?? GeometryTopologyTagFilterQuery(featureKind: kind)
    }

    func tagFilterResult(for featureKind: String) -> GeometryTopologyFilterSnapshot? {
        tagFilterResults[normalizedFilterFeatureKind(featureKind)]
    }

    func tagFilterIsLoading(for featureKind: String) -> Bool {
        tagFilterLoadingKinds.contains(normalizedFilterFeatureKind(featureKind))
    }

    func tagFilterError(for featureKind: String) -> String? {
        tagFilterErrors[normalizedFilterFeatureKind(featureKind)]
    }

    func tagFilterResultIsCurrent(for featureKind: String) -> Bool {
        let kind = normalizedFilterFeatureKind(featureKind)
        guard let result = tagFilterResults[kind],
              tagFilterResultQueryGeneration[kind] == tagFilterQueryGeneration[kind],
              let current = snapshot else { return false }
        return result.revision == current.revision
            && result.draftIdentity == GeometryTopologyCompletionResult.draftIdentity(for: current.draftState)
            && result.featureKind == kind
    }

    func updateTagFilterQuery(_ query: GeometryTopologyTagFilterQuery) {
        let kind = normalizedFilterFeatureKind(query.featureKind)
        activeTagFilterFeatureKind = kind
        guard query.hasValidShape else {
            tagFilterErrors[kind] = "The requested topology filter is no longer available."
            return
        }
        tagFilterQueries[kind] = GeometryTopologyTagFilterQuery(featureKind: kind, clauses: query.clauses)
        tagFilterQueryGeneration[kind, default: 0] += 1
        tagFilterResultQueryGeneration[kind] = nil
        tagFilterErrors[kind] = nil
    }

    /// Executes a read-only source filter. It does not submit a topology
    /// mutation and cannot affect dirty state or undo history.
    func applyTagFilterQuery(featureKind: String) async {
        let kind = normalizedFilterFeatureKind(featureKind)
        activeTagFilterFeatureKind = kind
        let query = tagFilterQuery(for: kind)
        guard query.hasValidShape,
              let capture = toolRequestCapture(),
              !isEditing else {
            tagFilterErrors[kind] = "The requested topology filter is no longer available."
            return
        }
        tagFilterGeneration[kind, default: 0] += 1
        let generation = tagFilterGeneration[kind, default: 0]
        let queryGeneration = tagFilterQueryGeneration[kind, default: 0]
        let request = GeometryTopologyFilterRequest(model: capture.model, revision: capture.sourceRevision,
            draftState: capture.draftState, featureKind: kind, clauses: query.clauses)
        tagFilterLoadingKinds.insert(kind)
        tagFilterErrors[kind] = nil
        defer {
            if tagFilterGeneration[kind] == generation { tagFilterLoadingKinds.remove(kind) }
        }
        do {
            let received = try await provider.filter(request)
            guard generation == tagFilterGeneration[kind], queryGeneration == tagFilterQueryGeneration[kind],
                  tagFilterQueries[kind] == query, toolCaptureIsCurrent(capture), !Task.isCancelled else { return }
            guard validate(received, featureKind: kind, capture: capture) else {
                tagFilterErrors[kind] = "The requested topology filter is no longer available."
                tagFilterResultQueryGeneration[kind] = nil
                return
            }
            tagFilterResults[kind] = received
            tagFilterResultQueryGeneration[kind] = queryGeneration
            tagFilterErrors[kind] = nil
        } catch {
            guard generation == tagFilterGeneration[kind], queryGeneration == tagFilterQueryGeneration[kind],
                  toolCaptureIsCurrent(capture), !Task.isCancelled else { return }
            tagFilterErrors[kind] = error.localizedDescription
            tagFilterResultQueryGeneration[kind] = nil
        }
    }

    func loadRecipe(controlPointFIDs: [Int]) async {
        guard pendingArcPointInputs.isEmpty else {
            setRecipeError("Apply or discard the pending topology input before changing the recipe selection.")
            return
        }
        guard let ids = sourceOrderedFeatureIDs(controlPointFIDs, featureKind: "region") else {
            setRecipeError("A selected topology control point is no longer available.")
            return
        }
        if let state = recipeEditorState, state.isPending {
            guard state.controlPointFIDs == ids else {
                setRecipeError("Apply or discard the pending topology input before changing the recipe selection.")
                return
            }
            await inspectRecipe(controlPointFIDs: ids, rawText: state.rawText)
            return
        }
        guard let capture = toolRequestCapture(), !isEditing else { return }
        recipeInspectionGeneration += 1
        let generation = recipeInspectionGeneration
        recipeInputGeneration += 1
        recipeEditorState = GeometryTopologyRecipeEditorState(controlPointFIDs: ids,
            sourceRevision: capture.sourceRevision, draftIdentity: capture.draftIdentity,
            rawText: "", baselineRawText: "", lastValidText: nil,
            inspection: nil, isInspecting: true, error: nil, isPending: false)
        do {
            let received = try await provider.inspectRecipe(capture.model, revision: capture.sourceRevision,
                draftState: capture.draftState, controlPointFIDs: ids, recipeText: nil)
            guard generation == recipeInspectionGeneration, toolCaptureIsCurrent(capture), !Task.isCancelled else { return }
            guard validate(received, controlPointFIDs: ids, capture: capture, expectedRawText: nil) else {
                setRecipeError("The selected topology control point is no longer available.")
                return
            }
            let baseline = received.commonRecipe ?? received.rawText
            recipeEditorState = GeometryTopologyRecipeEditorState(controlPointFIDs: ids,
                sourceRevision: capture.sourceRevision, draftIdentity: capture.draftIdentity,
                rawText: received.rawText, baselineRawText: baseline,
                lastValidText: received.isValid ? received.rawText : nil,
                inspection: received, isInspecting: false, error: nil, isPending: false)
        } catch {
            guard generation == recipeInspectionGeneration, toolCaptureIsCurrent(capture), !Task.isCancelled else { return }
            setRecipeError(error.localizedDescription)
        }
    }

    func updateRecipeInput(_ rawText: String, controlPointFIDs: [Int]) -> Bool {
        guard canEdit, !isEditing, pendingArcPointInputs.isEmpty,
              let ids = sourceOrderedFeatureIDs(controlPointFIDs, featureKind: "region"),
              let capture = toolRequestCapture() else { return false }
        if let state = recipeEditorState, state.isPending,
           (state.controlPointFIDs != ids || state.sourceRevision != capture.sourceRevision
            || state.draftIdentity != capture.draftIdentity) {
            setRecipeError("Apply or discard the pending topology input before changing the recipe selection.")
            return false
        }
        let state = recipeEditorState
        let baseline = state?.baselineRawText ?? (state?.inspection?.commonRecipe ?? "")
        let lastValid = state?.lastValidText
        recipeInputGeneration += 1
        recipeEditorState = GeometryTopologyRecipeEditorState(controlPointFIDs: ids,
            sourceRevision: capture.sourceRevision, draftIdentity: capture.draftIdentity,
            rawText: rawText, baselineRawText: baseline, lastValidText: lastValid,
            inspection: state?.inspection?.rawText == rawText ? state?.inspection : nil,
            isInspecting: false, error: nil, isPending: rawText != baseline)
        return true
    }

    func inspectRecipe(controlPointFIDs: [Int], rawText: String) async {
        guard let ids = sourceOrderedFeatureIDs(controlPointFIDs, featureKind: "region"),
              let capture = toolRequestCapture(), !isEditing else {
            setRecipeError("The selected topology control point is no longer available.")
            return
        }
        if recipeEditorState?.controlPointFIDs != ids || recipeEditorState?.rawText != rawText {
            guard updateRecipeInput(rawText, controlPointFIDs: ids) else { return }
        }
        recipeInspectionGeneration += 1
        let generation = recipeInspectionGeneration
        let inputGeneration = recipeInputGeneration
        guard var state = recipeEditorState else { return }
        state.isInspecting = true
        state.error = nil
        recipeEditorState = state
        do {
            let received = try await provider.inspectRecipe(capture.model, revision: capture.sourceRevision,
                draftState: capture.draftState, controlPointFIDs: ids, recipeText: rawText)
            guard generation == recipeInspectionGeneration, inputGeneration == recipeInputGeneration,
                  recipeEditorState?.rawText == rawText, toolCaptureIsCurrent(capture), !Task.isCancelled else { return }
            guard validate(received, controlPointFIDs: ids, capture: capture, expectedRawText: rawText) else {
                setRecipeError("The topology recipe could not be parsed.")
                return
            }
            guard var current = recipeEditorState else { return }
            current.inspection = received
            current.isInspecting = false
            current.error = nil
            if received.isValid { current.lastValidText = rawText }
            current.isPending = rawText != current.baselineRawText
            recipeEditorState = current
        } catch {
            guard generation == recipeInspectionGeneration, inputGeneration == recipeInputGeneration,
                  recipeEditorState?.rawText == rawText, toolCaptureIsCurrent(capture), !Task.isCancelled else { return }
            guard var current = recipeEditorState else { return }
            current.inspection = nil
            current.isInspecting = false
            current.error = error.localizedDescription
            current.isPending = rawText != current.baselineRawText
            recipeEditorState = current
        }
    }

    @discardableResult
    func restoreLastValidRecipe(controlPointFIDs: [Int]) -> String? {
        guard let state = recipeEditorState, let lastValid = state.lastValidText,
              state.controlPointFIDs == sourceOrderedFeatureIDs(controlPointFIDs, featureKind: "region") else { return nil }
        guard updateRecipeInput(lastValid, controlPointFIDs: controlPointFIDs) else { return nil }
        return lastValid
    }

    func applyRecipe(controlPointFIDs: [Int], forceSet: Bool) async {
        guard canEdit, !isEditing, pendingArcPointInputs.isEmpty,
              let ids = sourceOrderedFeatureIDs(controlPointFIDs, featureKind: "region"),
              !ids.isEmpty, let state = recipeEditorState, state.controlPointFIDs == ids,
              let inspection = state.inspection,
              inspection.rawText == state.rawText,
              inspection.revision == state.sourceRevision,
              inspection.draftIdentity == state.draftIdentity,
              state.sourceRevision == snapshot?.revision,
              state.draftIdentity == snapshot.map({ GeometryTopologyCompletionResult.draftIdentity(for: $0.draftState) }) else { return }
        // A mixed selection has no common baseline. In particular, clearing
        // its displayed recipe to the empty string can equal the empty
        // baseline while still being an intentional source Force Set.
        guard state.isPending || inspection.hasMismatch else { return }
        if inspection.hasMismatch && !forceSet {
            setRecipeError("Mixed topology recipes require explicit Force Set.")
            return
        }
        let mutation = GeometryTopologyMutation(operation: "applyRecipe", featureKind: "region", featureIDs: [],
            controlPointFeatureIDs: ids, recipeText: state.rawText, forceSet: forceSet)
        guard await submit(mutation, allowingPendingInput: true) else { return }
        recipeEditorState = nil
        recipeInputGeneration += 1
        await loadRecipe(controlPointFIDs: ids)
    }

    func restoreLastValidRecipeText(controlPointFIDs: [Int]) -> String? {
        restoreLastValidRecipe(controlPointFIDs: controlPointFIDs)
    }

    func loadArcPoints(arcFID: Int) async {
        guard let capture = toolRequestCapture(), !isEditing,
              snapshot?.arcs.rows.contains(where: { $0.fid == arcFID }) == true else {
            arcPointsError = "A selected topology arc is no longer available."
            return
        }
        arcPointsGeneration += 1
        let generation = arcPointsGeneration
        isLoadingArcPoints = true
        arcPointsError = nil
        defer { if generation == arcPointsGeneration { isLoadingArcPoints = false } }
        do {
            let received = try await provider.arcPoints(capture.model, revision: capture.sourceRevision,
                draftState: capture.draftState, arcFID: arcFID)
            guard generation == arcPointsGeneration, toolCaptureIsCurrent(capture), !Task.isCancelled else { return }
            guard validate(received, arcFID: arcFID, capture: capture) else {
                arcPointsError = "A selected topology arc is no longer available."
                return
            }
            arcPoints = received
        } catch {
            guard generation == arcPointsGeneration, toolCaptureIsCurrent(capture), !Task.isCancelled else { return }
            arcPointsError = error.localizedDescription
        }
    }

    @discardableResult
    func updateArcPointInput(arcFID: Int, rowIndex: Int, axis: GeometryTopologyCoordinateAxis,
                             rawText: String) -> Bool {
        guard canEdit, !isEditing, recipeEditorState?.isPending != true,
              let current = snapshot, let arcPoints,
              arcPoints.arcFID == arcFID, arcPoints.revision == current.revision,
              arcPoints.draftIdentity == GeometryTopologyCompletionResult.draftIdentity(for: current.draftState),
              let row = arcPoints.rows.first(where: { $0.rowIndex == rowIndex }),
              current.arcs.rows.first(where: { $0.fid == arcFID }) != nil else { return false }
        let key = GeometryTopologyArcPointInputDraft(sourceRevision: current.revision,
            draftIdentity: arcPoints.draftIdentity, arcFID: arcFID, rowIndex: rowIndex,
            pointKind: row.pointKind, internalPointIndex: row.internalPointIndex,
            endpointNodeIndex: row.endpointNodeIndex, axis: axis, rawText: rawText)
        let pending = pendingArcPointInput
        if let pending, pending.id != key.id { return false }
        if pending == key { return true }
        if pending == nil { pendingArcPointInputOrder.append(key.id) }
        pendingArcPointInputs[key.id] = key
        arcPointsError = nil
        return true
    }

    func applyArcPointInput() async {
        guard canEdit, !isEditing, recipeEditorState?.isPending != true,
              let pending = pendingArcPointInput,
              let current = snapshot,
              pending.sourceRevision == current.revision,
              pending.draftIdentity == GeometryTopologyCompletionResult.draftIdentity(for: current.draftState),
              current.arcs.rows.contains(where: { $0.fid == pending.arcFID }) else {
            arcPointsError = "A selected topology arc is no longer available."
            return
        }
        let ownerAssetID = currentAsset?.id
        let ownerModel = currentModel
        let editedArcFID = pending.arcFID
        let mutation = GeometryTopologyMutation(operation: "setArcPointCoordinate", featureKind: "arc",
            featureIDs: [pending.arcFID], pointKind: pending.pointKind,
            internalPointIndex: pending.internalPointIndex, endpointNodeIndex: pending.endpointNodeIndex,
            axis: pending.axis.rawValue, rawValue: pending.rawText)
        guard await submit(mutation, allowingPendingInput: true) else { return }
        pendingArcPointInputs.removeValue(forKey: pending.id)
        pendingArcPointInputOrder.removeAll { $0 == pending.id }
        guard currentAsset?.id == ownerAssetID, currentModel == ownerModel,
              let committedRow = snapshot?.arcs.rows.first(where: { $0.fid == editedArcFID }),
              selectedFeatureIDs["arc", default: []].contains(committedRow.id) else { return }
        // submit invalidates all source-backed point rows when the opaque draft
        // identity changes, so the prior snapshot can no longer guard refresh.
        await loadArcPoints(arcFID: editedArcFID)
    }

    func discardPendingInputs() {
        guard !parentSaveInProgress else { return }
        pendingArcPointInputs.removeAll()
        pendingArcPointInputOrder.removeAll()
        recipeInputGeneration += 1
        recipeInspectionGeneration += 1
        if var state = recipeEditorState {
            state.rawText = state.baselineRawText
            state.isPending = false
            state.isInspecting = false
            state.inspection = nil
            state.error = nil
            recipeEditorState = state
        }
        arcPointsError = nil
    }

    private func normalizedFilterFeatureKind(_ featureKind: String) -> String {
        featureKind == "controlPoint" ? "region" : featureKind
    }

    private func sourceOrderedFeatureIDs(_ fids: [Int], featureKind: String) -> [Int]? {
        let table = self.table(for: featureKind)
        let requested = Set(fids)
        guard requested.count == fids.count,
              requested.allSatisfy({ fid in table.rows.contains(where: { $0.fid == fid }) }) else { return nil }
        return table.rows.map(\.fid).filter(requested.contains)
    }

    private func sourceOrderedFeatureIDs(_ rowIDs: [String], featureKind: String) -> [Int]? {
        let rows = table(for: featureKind).rows
        let requested = Set(rowIDs)
        guard !rowIDs.isEmpty, requested.count == rowIDs.count,
              requested.allSatisfy({ id in rows.contains(where: { $0.id == id }) }) else { return nil }
        return rows.filter { requested.contains($0.id) }.map(\.fid)
    }

    private func toolRequestCapture() -> GeometryTopologyToolRequestCapture? {
        guard let currentModel, let assetID = currentAsset?.id, let snapshot,
              !snapshot.revision.isEmpty else { return nil }
        return GeometryTopologyToolRequestCapture(model: currentModel, assetID: assetID,
            sourceRevision: snapshot.revision, draftState: snapshot.draftState,
            draftIdentity: GeometryTopologyCompletionResult.draftIdentity(for: snapshot.draftState),
            modelGeneration: modelGeneration, loadGeneration: loadGeneration)
    }

    private func toolCaptureIsCurrent(_ capture: GeometryTopologyToolRequestCapture) -> Bool {
        guard let current = snapshot else { return false }
        return currentAsset?.id == capture.assetID && currentModel == capture.model
            && modelGeneration == capture.modelGeneration && loadGeneration == capture.loadGeneration
            && current.revision == capture.sourceRevision
            && current.draftState == capture.draftState
            && GeometryTopologyCompletionResult.draftIdentity(for: current.draftState) == capture.draftIdentity
    }

    private func validate(_ received: GeometryTopologyFilterSnapshot, featureKind: String,
                          capture: GeometryTopologyToolRequestCapture) -> Bool {
        guard received.revision == capture.sourceRevision, received.draftIdentity == capture.draftIdentity,
              received.featureKind == featureKind else { return false }
        let rows = table(for: featureKind == "region" ? "region" : "arc").rows
        let rowIDs = Set(rows.map(\.fid))
        guard Set(received.matchedFeatureIDs).count == received.matchedFeatureIDs.count,
              received.matchedFeatureIDs.allSatisfy(rowIDs.contains) else { return false }
        let sourceOrder = rows.map(\.fid).filter(Set(received.matchedFeatureIDs).contains)
        guard sourceOrder == received.matchedFeatureIDs else { return false }
        let descriptors = received.propertyDescriptors
        guard Set(descriptors.map(\.columnName)).count == descriptors.count,
              descriptors.allSatisfy({ !$0.columnName.isEmpty && !$0.name.isEmpty }) else { return false }
        let tags = received.tagDefinitions
        return Set(tags.map(\.id)).count == tags.count && tags.allSatisfy({ !$0.id.isEmpty })
    }

    private func validate(_ received: GeometryTopologyRecipeSnapshot, controlPointFIDs: [Int],
                          capture: GeometryTopologyToolRequestCapture, expectedRawText: String?) -> Bool {
        guard received.revision == capture.sourceRevision, received.draftIdentity == capture.draftIdentity,
              received.controlPointFIDs == controlPointFIDs,
              received.hasSelection == !controlPointFIDs.isEmpty,
              (expectedRawText == nil || received.rawText == expectedRawText) else { return false }
        let selectedIDs = received.selectedRecipes.map(\.fid)
        guard selectedIDs == controlPointFIDs,
              Set(received.stepSchema.map(\.name)).count == received.stepSchema.count,
              received.stepSchema.allSatisfy({ !$0.name.isEmpty && Set($0.parameters.map(\.name)).count == $0.parameters.count }) else {
            return false
        }
        return true
    }

    private func validate(_ received: GeometryTopologyArcPointsSnapshot, arcFID: Int,
                          capture: GeometryTopologyToolRequestCapture) -> Bool {
        guard received.revision == capture.sourceRevision, received.draftIdentity == capture.draftIdentity,
              received.arcFID == arcFID, let arc = snapshot?.arcs.rows.first(where: { $0.fid == arcFID }),
              received.rows.count >= 2 else { return false }
        for (index, point) in received.rows.enumerated() {
            guard point.rowIndex == index, point.x.isFinite, point.y.isFinite else { return false }
            if index == 0 {
                guard point.pointKind == "start", point.internalPointIndex == nil,
                      point.endpointNodeIndex == arc.startNodeID else { return false }
            } else if index == received.rows.count - 1 {
                guard point.pointKind == "end", point.internalPointIndex == nil,
                      point.endpointNodeIndex == arc.endNodeID else { return false }
            } else {
                guard point.pointKind == "internal", point.endpointNodeIndex == nil,
                      point.internalPointIndex == index - 1 else { return false }
            }
        }
        return true
    }

    private func setRecipeError(_ message: String) {
        guard var state = recipeEditorState else {
            recipeEditorState = GeometryTopologyRecipeEditorState(controlPointFIDs: [],
                sourceRevision: snapshot?.revision ?? "",
                draftIdentity: snapshot.map { GeometryTopologyCompletionResult.draftIdentity(for: $0.draftState) } ?? "",
                rawText: "", baselineRawText: "", lastValidText: nil,
                inspection: nil, isInspecting: false, error: message, isPending: false)
            return
        }
        state.error = message
        state.isInspecting = false
        recipeEditorState = state
    }

    private func clearTopologyToolState() {
        arcPointsGeneration += 1
        recipeInspectionGeneration += 1
        recipeInputGeneration += 1
        tagFilterGeneration = tagFilterGeneration.mapValues { $0 + 1 }
        tagFilterQueries = ["arc": GeometryTopologyTagFilterQuery(featureKind: "arc"),
                            "region": GeometryTopologyTagFilterQuery(featureKind: "region")]
        tagFilterResults.removeAll()
        tagFilterLoadingKinds.removeAll()
        tagFilterErrors.removeAll()
        tagFilterResultQueryGeneration.removeAll()
        tagFilterQueryGeneration = ["arc": 0, "region": 0]
        activeTagFilterFeatureKind = "arc"
        arcPoints = nil
        isLoadingArcPoints = false
        arcPointsError = nil
        recipeEditorState = nil
        pendingArcPointInputs.removeAll()
        pendingArcPointInputOrder.removeAll()
    }

    func setField(featureKind: String, fid: Int, fieldID: String, value: String) async {
        await submit(.init(operation: "setField", featureKind: featureKind, featureIDs: [fid], fieldID: fieldID, value: value))
    }

    /// Mirrors the source multi-selection ForceReset* commands. Only a real
    /// mismatch is actionable, and the command carries stable source control
    /// point FIDs in source-table order rather than display names.
    func resetRegionField(controlPointFIDs: [Int], fieldID: String) async {
        let resettableFields: Set<String> = ["ConstantSize", "SecondaryConstantSize", "RotationDegrees",
            "BiasInternal", "TinResolution", "SizeTolerance"]
        guard canMutateTopology, resettableFields.contains(fieldID),
              let orderedFIDs = sourceOrderedFeatureIDs(controlPointFIDs, featureKind: "region"),
              orderedFIDs.count > 1 else { return }
        let rowsByFID = Dictionary(uniqueKeysWithValues: table(for: "region").rows.map { ($0.fid, $0) })
        let values = orderedFIDs.compactMap { rowsByFID[$0]?.values[fieldID] }
        guard values.count == orderedFIDs.count, sourceFloatValuesDiffer(values) else { return }
        await submit(.init(operation: "forceResetField", featureKind: "region",
            featureIDs: orderedFIDs, fieldID: fieldID))
    }

    /// Applies the original multi-selection PatchType ForceSet command to the
    /// exact selected region row identities. The mutation is recorded in the
    /// topology draft and is committed only by the normal parent geometry save.
    @discardableResult
    func forceSetPatchType(rowIDs: [String], patchType: String) async -> Bool {
        let allowed: Set<String> = ["Quad", "TrianglePaver", "Cartesian", "OneD", "Empty"]
        guard canMutateTopology, allowed.contains(patchType),
              let orderedFIDs = sourceOrderedFeatureIDs(rowIDs, featureKind: "region"),
              !orderedFIDs.isEmpty else { return false }
        return await submit(.init(operation: "forceSetPatchType", featureKind: "region", featureIDs: [],
            value: patchType, controlPointFeatureIDs: orderedFIDs))
    }

    /// SourceField clear-command adapter for the six conceptual-mesh inputs.
    /// Stable row identities are resolved in the current source-table order;
    /// empty, duplicate, stale, and single-row selections cannot issue a
    /// multi-source ForceReset.
    @discardableResult
    func resetRegionField(rowIDs: [String], fieldID: String) async -> Bool {
        let resettableFields: Set<String> = ["ConstantSize", "SecondaryConstantSize", "RotationDegrees",
            "BiasInternal", "TinResolution", "SizeTolerance"]
        guard canMutateTopology, resettableFields.contains(fieldID),
              let orderedFIDs = sourceOrderedFeatureIDs(rowIDs, featureKind: "region"),
              orderedFIDs.count > 1 else { return false }
        let rowsByFID = Dictionary(uniqueKeysWithValues: table(for: "region").rows.map { ($0.fid, $0) })
        let values = orderedFIDs.compactMap { rowsByFID[$0]?.values[fieldID] }
        guard values.count == orderedFIDs.count, sourceFloatValuesDiffer(values) else { return false }
        return await submit(.init(operation: "forceResetField", featureKind: "region",
            featureIDs: orderedFIDs, fieldID: fieldID))
    }

    /// Returns the source-form text aggregate for the exact currently selected
    /// region row identities. Mixed and missing values are shown as the
    /// original empty-text presentation, while `isMixed` preserves the source
    /// selection's mismatch state for the native text control.
    func regionInputText(rowIDs: [String], fieldID: String) -> (value: String, isMixed: Bool)? {
        let editableFields: Set<String> = ["ConstantSize", "SecondaryConstantSize", "RotationDegrees",
            "BiasInternal", "TinResolution", "SizeTolerance"]
        guard editableFields.contains(fieldID), !rowIDs.isEmpty,
              let orderedFIDs = sourceOrderedFeatureIDs(rowIDs, featureKind: "region") else { return nil }
        let rowsByFID = Dictionary(uniqueKeysWithValues: table(for: "region").rows.map { ($0.fid, $0) })
        let values = orderedFIDs.compactMap { rowsByFID[$0]?.values[fieldID] }
        guard values.count == orderedFIDs.count, let first = values.first else { return nil }
        let mixed = values.dropFirst().contains { $0 != first }
        return (mixed ? "" : first, mixed)
    }

    /// Serializes source-style live text setters into the existing geometry
    /// topology draft. Each request retains exact selected row identities and
    /// the loaded model generation; writes never reach the HDF until the
    /// ordinary parent geometry save.
    @discardableResult
    func enqueueRegionInput(rowIDs: [String], fieldID: String, value: String,
                            completion: @escaping @MainActor (Bool) -> Void) -> Bool {
        let editableFields: Set<String> = ["ConstantSize", "SecondaryConstantSize", "RotationDegrees",
            "BiasInternal", "TinResolution", "SizeTolerance"]
        guard editableFields.contains(fieldID), canEdit, !parentSaveInProgress,
              recipeEditorState?.isPending != true, pendingArcPointInputs.isEmpty,
              (!isEditing || regionInputWriteWorker != nil),
              let currentModel, let assetID = currentAsset?.id, let snapshot,
              !snapshot.revision.isEmpty,
              sourceOrderedFeatureIDs(rowIDs, featureKind: "region") != nil else { return false }

        pendingRegionInputWrites.append(PendingGeometryRegionInputWrite(
            loadGeneration: loadGeneration, modelGeneration: modelGeneration,
            assetID: assetID, model: currentModel, sourceRevision: snapshot.revision,
            rowIDs: rowIDs, fieldID: fieldID, value: value, completion: completion))
        if regionInputWriteWorker == nil {
            let workerID = UUID()
            regionInputWriteWorkerID = workerID
            regionInputWriteWorker = Task { @MainActor [weak self] in
                await self?.drainRegionInputWrites(workerID: workerID)
            }
        }
        return true
    }

    private func drainRegionInputWrites(workerID: UUID) async {
        while regionInputWriteWorkerID == workerID, !Task.isCancelled,
              !pendingRegionInputWrites.isEmpty {
            let write = pendingRegionInputWrites.removeFirst()
            guard !Task.isCancelled,
                  loadGeneration == write.loadGeneration,
                  modelGeneration == write.modelGeneration,
                  currentAsset?.id == write.assetID,
                  currentModel == write.model,
                  snapshot?.revision == write.sourceRevision,
                  !parentSaveInProgress,
                  recipeEditorState?.isPending != true,
                  pendingArcPointInputs.isEmpty,
                  let orderedFIDs = sourceOrderedFeatureIDs(write.rowIDs, featureKind: "region") else {
                write.completion(false)
                continue
            }
            let mutation = GeometryTopologyMutation(operation: "setRegionInput", featureKind: "region",
                featureIDs: orderedFIDs, fieldID: write.fieldID, value: write.value)
            let didApply = await submit(mutation, allowingQueuedRegionInput: true)
            write.completion(didApply)
        }
        if regionInputWriteWorkerID == workerID {
            regionInputWriteWorker = nil
            regionInputWriteWorkerID = nil
        }
    }

    private func sourceFloatValuesDiffer(_ values: [String]) -> Bool {
        guard let firstText = values.first, let first = Float(firstText) else { return false }
        return values.dropFirst().contains { text in
            guard let value = Float(text) else { return true }
            return first != value && !(first.isNaN && value.isNaN)
        }
    }

    func adjustSize(featureKind: String, fid: Int, half: Bool, axis: String? = nil) async {
        await submit(.init(operation: half ? "halfSize" : "doubleSize", featureKind: featureKind,
            featureIDs: [fid], fieldID: axis))
    }

    func createTag(featureKind: String, name: String, type: String) async {
        await submit(.init(operation: "createTag", featureKind: featureKind, featureIDs: [], tagName: name, tagType: type))
    }

    @discardableResult
    func editMetadataColumn(operation: GeometryTopologyMetadataColumnOperation,
                            featureKind: GeometryTopologyMetadataColumnKind,
                            fieldID: String, value: String? = nil) async -> Bool {
        await submit(.init(operation: operation.rawValue, featureKind: featureKind.rawValue,
            featureIDs: [], fieldID: fieldID, value: value))
    }

    func setTag(featureKind: String, featureIDs: [Int], name: String, value: String) async {
        await submit(.init(operation: "setTag", featureKind: featureKind, featureIDs: featureIDs, tagName: name, tagValue: value))
    }

    func removeTag(featureKind: String, featureIDs: [Int], name: String) async {
        await submit(.init(operation: "removeTag", featureKind: featureKind, featureIDs: featureIDs, tagName: name))
    }

    func undo() async {
        guard canUndo else { return }
        let undoMutation = historyMutation(for: snapshot?.draftState)?.mutations.last
        guard await submit(.init(operation: "undo", featureKind: "history", featureIDs: [])) else { return }
        if undoMutation?.operation == "deleteSelection" {
            selectedFeatureIDs = restoredSelection(from: undoMutation!)
        }
    }

    func redo() async {
        guard canRedo else { return }
        let redoMutation = historyMutation(for: snapshot?.draftState)?.redoMutations.last
        guard await submit(.init(operation: "redo", featureKind: "history", featureIDs: [])) else { return }
        if redoMutation?.operation == "deleteSelection" {
            selectedFeatureIDs = ["arc": [], "region": [], "node": []]
        }
    }

    private func historyMutation(for draftState: String?) -> GeometryTopologyDraftPayload? {
        guard let draftState, let data = draftState.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GeometryTopologyDraftPayload.self, from: data)
    }

    private func restoredSelection(from mutation: GeometryTopologyMutation) -> [String: Set<String>] {
        func rowIDs(_ fids: [Int], featureKind: String) -> Set<String> {
            let selected = Set(fids)
            return Set(table(for: featureKind).rows.filter { selected.contains($0.fid) }.map(\.id))
        }
        return ["arc": rowIDs(mutation.arcFeatureIDs, featureKind: "arc"),
            "region": rowIDs(mutation.controlPointFeatureIDs, featureKind: "region"),
            "node": rowIDs(mutation.nodeFeatureIDs, featureKind: "node")]
    }

    /// A nil return means the child is busy. A capture with nil draft state is
    /// still valid and lets ordinary geometry edits save without loading the
    /// topology page first.
    func beginParentSave() -> GeometryTopologyParentSaveCapture? {
        guard canBeginParentSave else { return nil }
        let operationID = UUID()
        activeParentSaveID = operationID
        parentSaveInProgress = true
        return GeometryTopologyParentSaveCapture(operationID: operationID, generation: modelGeneration,
            assetID: currentAsset?.id, draftState: topologyStateForParentSave,
            sourceRevision: snapshot?.revision)
    }

    /// HDF save has already succeeded when this is called. Clear only the
    /// captured draft before attempting a fresh read, so a read failure cannot
    /// replay saved mutations against the new file revision.
    func acknowledgeParentSave(_ capture: GeometryTopologyParentSaveCapture, newSourceRevision: String?) async {
        guard parentCaptureIsCurrent(capture) else { return }
        guard let asset = currentAsset, let model = currentModel else {
            releaseParentSave(capture)
            return
        }
        guard topologyStateForParentSave == capture.draftState else {
            releaseParentSave(capture)
            return
        }
        let hadCapturedDraft = capture.draftState != nil
        expectedSourceRevision = newSourceRevision
        clearTopologyToolState()
        let recentArcTags = snapshot?.recentArcTags ?? []
        let recentRegionTags = snapshot?.recentRegionTags ?? []
        if let current = snapshot {
            snapshot = GeometryTopologySnapshot(revision: newSourceRevision ?? current.revision,
                draftState: cleanDraftState(model: model, revision: newSourceRevision ?? current.revision,
                    recentArcTags: recentArcTags, recentRegionTags: recentRegionTags),
                canEdit: current.canEdit, isDirty: false, arcs: current.arcs, regions: current.regions,
                nodes: current.nodes, arcTags: current.arcTags, regionTags: current.regionTags,
                recentArcTags: recentArcTags, recentRegionTags: recentRegionTags, map: current.map,
                canUndo: false, canRedo: false, completion: nil)
        }
        clearDiagnosticFocus()
        if hadCapturedDraft { onParentDraftChange(false) }
        await fetch(model: model, expectedRevision: newSourceRevision, asset: asset)
        if let refreshed = snapshot, refreshed.revision == (newSourceRevision ?? refreshed.revision) {
            snapshot = GeometryTopologySnapshot(revision: refreshed.revision,
                draftState: refreshed.draftState,
                canEdit: refreshed.canEdit, isDirty: refreshed.isDirty, arcs: refreshed.arcs, regions: refreshed.regions,
                nodes: refreshed.nodes, arcTags: refreshed.arcTags, regionTags: refreshed.regionTags,
                recentArcTags: recentArcTags, recentRegionTags: recentRegionTags, map: refreshed.map,
                canUndo: refreshed.canUndo, canRedo: refreshed.canRedo, completion: refreshed.completion)
        }
        releaseParentSave(capture)
    }

    func parentSaveFailed(_ capture: GeometryTopologyParentSaveCapture) {
        guard parentCaptureIsCurrent(capture) else { return }
        releaseParentSave(capture)
    }

    /// Discard invalidates any in-flight edit before reloading source data.
    func discardDraft() async {
        guard !parentSaveInProgress else { return }
        let hadDraft = isDirty
        loadGeneration += 1
        isEditing = false
        isLoading = false
        didLoad = false
        snapshot = nil
        expectedSourceRevision = nil
        selectedFeatureIDs = ["arc": [], "region": [], "node": []]
        clearDiagnosticFocus()
        clearTopologyToolState()
        error = nil
        if hadDraft { onParentDraftChange(false) }
        await reload(expectedRevision: nil)
    }

    private func reload(expectedRevision: String?) async {
        guard let model = currentModel, let asset = currentAsset else { return }
        await fetch(model: model, expectedRevision: expectedRevision, asset: asset)
    }

    private func fetch(model: GeometryTopologyModelRequest, expectedRevision: String?, asset: ProjectAsset) async {
        loadGeneration += 1
        let generation = loadGeneration
        let hadDraft = isDirty
        let previousSourceRevision = snapshot?.revision
        let previousDraftState = snapshot?.draftState
        if let snapshot { self.snapshot = replacingCompletion(in: snapshot, with: nil) }
        clearDiagnosticFocus()
        isLoading = true
        error = nil
        defer {
            if generation == loadGeneration { isLoading = false }
        }
        do {
            let loaded = try await provider.load(model, expectedRevision: expectedRevision)
            guard generation == loadGeneration, currentAsset?.id == asset.id,
                  currentModel == model, !Task.isCancelled else { return }
            if previousSourceRevision != loaded.revision || previousDraftState != loaded.draftState {
                clearTopologyToolState()
            }
            accept(loaded)
            expectedSourceRevision = loaded.revision
            didLoad = true
            selectedFeatureIDs = ["arc": [], "region": [], "node": []]
            // Retained completion can repair topology during Load. Those
            // in-memory edits must enable the parent's Save/Discard flow.
            if hadDraft != isDirty { onParentDraftChange(isDirty) }
        } catch {
            guard generation == loadGeneration, currentAsset?.id == asset.id,
                  currentModel == model, !Task.isCancelled else { return }
            self.error = error.localizedDescription
            didLoad = false
        }
    }

    /// Reads real Shapefile features against this exact parent topology draft.
    /// The source reader returns coordinates in the project's world space.
    func inspectVectorImport(paths: [String]) async throws -> GeometryVectorImportInspection {
        guard canMutateTopology, !parentSaveInProgress,
              let capture = toolRequestCapture() else {
            throw GeometryVectorImportSessionError.parentUnavailable
        }
        guard !paths.isEmpty, Set(paths).count == paths.count else {
            throw GeometryVectorImportSessionError.invalidSelection
        }
        isEditing = true
        error = nil
        defer { if capture.loadGeneration == loadGeneration { isEditing = false } }

        let request = GeometryVectorImportInspectRequest(model: capture.model,
            revision: capture.sourceRevision, draftState: capture.draftState,
            draftIdentity: capture.draftIdentity, paths: paths)
        let inspection = try await provider.inspectVectorImport(request)
        guard toolCaptureIsCurrent(capture), !Task.isCancelled else {
            throw GeometryVectorImportSessionError.staleContext
        }
        guard inspection.revision == capture.sourceRevision,
              inspection.draftIdentity == capture.draftIdentity,
              Set(inspection.sources.map(\.path)).count == inspection.sources.count,
              inspection.sources.allSatisfy({ source in
                  source.family.family == "shapefile" && source.path == source.family.sourcePath
                      && !source.path.isEmpty && source.featureCount == source.features.count
                      && source.features.allSatisfy({ feature in
                          ["polyline", "polygon"].contains(feature.geometryType)
                              && feature.points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
                      })
              }) else {
            throw GeometryVectorImportSessionError.invalidResponse
        }
        return inspection
    }

    /// Re-reads the inspected file families, then records their actual
    /// project-space coordinates as one replayable parent topology mutation.
    @discardableResult
    func applyVectorImport(_ inspection: GeometryVectorImportInspection,
                           sourcePaths: [String], options: GeometryVectorImportOptions) async throws -> Bool {
        guard canMutateTopology, !parentSaveInProgress,
              let capture = toolRequestCapture() else {
            throw GeometryVectorImportSessionError.parentUnavailable
        }
        guard !sourcePaths.isEmpty, Set(sourcePaths).count == sourcePaths.count,
              inspection.revision == capture.sourceRevision,
              inspection.draftIdentity == capture.draftIdentity,
              toolCaptureIsCurrent(capture) else {
            throw GeometryVectorImportSessionError.staleContext
        }
        let byPath = Dictionary(uniqueKeysWithValues: inspection.sources.map { ($0.path, $0) })
        guard sourcePaths.allSatisfy({ byPath[$0] != nil }) else {
            throw GeometryVectorImportSessionError.invalidSelection
        }
        let sources = sourcePaths.compactMap { path -> GeometryVectorImportSelectedSource? in
            guard let source = byPath[path] else { return nil }
            return GeometryVectorImportSelectedSource(path: source.path, family: source.family)
        }

        isEditing = true
        error = nil
        defer { if capture.loadGeneration == loadGeneration { isEditing = false } }
        let request = GeometryVectorImportApplyRequest(model: capture.model,
            revision: capture.sourceRevision, draftState: capture.draftState,
            draftIdentity: capture.draftIdentity, sources: sources,
            mode: options.mode.rawValue, mergeContiguousArcs: options.mergeContiguousArcs,
            removeExternalArcs: options.removeExternalArcs)
        let updated = try await provider.applyVectorImport(request)
        guard toolCaptureIsCurrent(capture), !Task.isCancelled else {
            throw GeometryVectorImportSessionError.staleContext
        }
        guard updated.revision == capture.sourceRevision, updated.isDirty,
              updated.draftState != capture.draftState else {
            throw GeometryVectorImportSessionError.invalidResponse
        }
        accept(updated)
        invalidateToolQueriesAfterDraftChange()
        onParentDraftChange(updated.isDirty)
        return true
    }

    @discardableResult
    private func submit(_ mutation: GeometryTopologyMutation, allowingPendingInput: Bool = false,
                        allowingQueuedRegionInput: Bool = false) async -> Bool {
        let canSubmitWithQueuedRegionInput = allowingQueuedRegionInput
            && recipeEditorState?.isPending != true && pendingArcPointInputs.isEmpty
        guard canEdit, !isEditing,
              (allowingPendingInput || canSubmitWithQueuedRegionInput || !hasPendingInputs),
              let current = snapshot, let model = currentModel,
              let assetID = currentAsset?.id else { return false }
        let generation = loadGeneration
        let previousDraftState = current.draftState
        isEditing = true
        if let snapshot { self.snapshot = replacingCompletion(in: snapshot, with: nil) }
        clearDiagnosticFocus()
        error = nil
        defer {
            if generation == loadGeneration { isEditing = false }
        }
        do {
            let updated = try await provider.edit(model, revision: current.revision,
                draftState: current.draftState, mutation: mutation)
            guard generation == loadGeneration, currentAsset?.id == assetID,
                  currentModel == model, !Task.isCancelled else { return false }
            accept(updated)
            if updated.draftState != previousDraftState { invalidateToolQueriesAfterDraftChange() }
            onParentDraftChange(updated.isDirty)
            return true
        } catch {
            guard generation == loadGeneration, currentAsset?.id == assetID,
                  currentModel == model, !Task.isCancelled else { return false }
            self.error = error.localizedDescription
            return false
        }
    }

    private func invalidateToolQueriesAfterDraftChange() {
        arcPointsGeneration += 1
        arcPoints = nil
        isLoadingArcPoints = false
        arcPointsError = nil
        recipeInspectionGeneration += 1
        if recipeEditorState?.isPending != true { recipeEditorState = nil }
        for kind in ["arc", "region"] {
            tagFilterGeneration[kind, default: 0] += 1
            tagFilterLoadingKinds.remove(kind)
            tagFilterResultQueryGeneration[kind] = nil
        }
    }

    private func parentCaptureIsCurrent(_ capture: GeometryTopologyParentSaveCapture) -> Bool {
        activeParentSaveID == capture.operationID && modelGeneration == capture.generation
            && currentAsset?.id == capture.assetID
    }

    private func releaseParentSave(_ capture: GeometryTopologyParentSaveCapture) {
        guard parentCaptureIsCurrent(capture) else { return }
        activeParentSaveID = nil
        parentSaveInProgress = false
    }

    private func cleanDraftState(model: GeometryTopologyModelRequest, revision: String,
                                 recentArcTags: [GeometryTopologyRecentTag],
                                 recentRegionTags: [GeometryTopologyRecentTag]) -> String {
        let payload = GeometryTopologyDraftPayload(assetPath: model.assetPath, revision: revision,
            mutations: [], redoMutations: [], recentArcTags: recentArcTags, recentRegionTags: recentRegionTags)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload), let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    private func accept(_ received: GeometryTopologySnapshot) {
        let accepted: GeometryTopologySnapshot
        if let completion = received.completion,
           (completion.sourceRevision != received.revision
            || completion.draftIdentity != GeometryTopologyCompletionResult.draftIdentity(for: received.draftState)) {
            accepted = replacingCompletion(in: received, with: nil)
            error = "The topology completion result does not match the current source draft."
        } else {
            accepted = received
        }
        if let previous = snapshot {
            if tagDefinitionIdentity(previous.arcTags) != tagDefinitionIdentity(accepted.arcTags) {
                clearTagFilterState(for: "arc")
            }
            if tagDefinitionIdentity(previous.regionTags) != tagDefinitionIdentity(accepted.regionTags) {
                clearTagFilterState(for: "region")
            }
        }
        if snapshot?.completion?.draftIdentity != accepted.completion?.draftIdentity {
            clearDiagnosticFocus()
        }
        snapshot = accepted
        for featureKind in ["arc", "region", "node"] {
            let available = Set(table(for: featureKind).rows.map(\.id))
            selectedFeatureIDs[featureKind, default: []].formIntersection(available)
        }
    }

    private func tagDefinitionIdentity(_ definitions: [GeometryTopologyTagDefinition]) -> [[String]] {
        definitions.map { [$0.id, $0.type] }
    }

    private func clearTagFilterState(for featureKind: String) {
        tagFilterGeneration[featureKind, default: 0] += 1
        tagFilterQueryGeneration[featureKind, default: 0] += 1
        tagFilterQueries[featureKind] = GeometryTopologyTagFilterQuery(featureKind: featureKind)
        tagFilterResults.removeValue(forKey: featureKind)
        tagFilterResultQueryGeneration.removeValue(forKey: featureKind)
        tagFilterLoadingKinds.remove(featureKind)
        tagFilterErrors.removeValue(forKey: featureKind)
    }

    private func replacingCompletion(in snapshot: GeometryTopologySnapshot,
                                     with completion: GeometryTopologyCompletionResult?) -> GeometryTopologySnapshot {
        GeometryTopologySnapshot(revision: snapshot.revision, draftState: snapshot.draftState,
            canEdit: snapshot.canEdit, isDirty: snapshot.isDirty, arcs: snapshot.arcs, regions: snapshot.regions,
            nodes: snapshot.nodes, arcTags: snapshot.arcTags, regionTags: snapshot.regionTags,
            recentArcTags: snapshot.recentArcTags, recentRegionTags: snapshot.recentRegionTags, map: snapshot.map,
            canUndo: snapshot.canUndo, canRedo: snapshot.canRedo, completion: completion)
    }

    private func clearDiagnosticFocus() {
        selectedDiagnosticMessageID = nil
        selectedDiagnosticTargets = []
        diagnosticMapFeatureIDs = []
    }
}

private extension GeometryTopologyCompletionMessage {
    var presentation: TopologyBuildMessagePresentation {
        let severity = TopologyMessageSeverity(rawValue: severity.lowercased()) ?? .information
        let context = logData.enumerated().map { index, value in
            TopologyBuildContextValue(id: "\(index):\(value.key)", key: value.key, value: value.value,
                valueType: value.valueType, integerValue: value.integerValue)
        }
        return TopologyBuildMessagePresentation(id: id, severity: severity, code: code, text: text,
            context: context, sourceSeverity: self.severity,
            regionCompletionSeverity: regionCompletionSeverity, targets: targets)
    }
}
