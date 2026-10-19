import Foundation
import CryptoKit
import RASWorkspaceCore
import SwiftUI

struct GeometryCulvertParentSaveCapture: Sendable {
    let operationID: UUID
    let generation: Int
    let assetID: String?
    let draftState: String?
    let sourceRevision: String?
}

/// Owns the three source culvert tables as one geometry child draft. The
/// parent submits its opaque state with ordinary geometry, mesh and topology
/// edits through one staged HDF save.
@MainActor
final class GeometryCulvertSession: ObservableObject {
    private let provider: any GeometryCulvertProvider
    var onParentDraftChange: @MainActor (Bool) -> Void = { _ in }
    private var currentAsset: ProjectAsset?
    private var currentModel: GeometryCulvertModelRequest?
    private var expectedSourceRevision: String?
    private var didLoad = false
    private var loadGeneration = 0
    private var modelGeneration = 0
    private var activeParentSaveID: UUID?
    private var pendingSketchContext: (asset: ProjectAsset, sourceRevision: String?)?
    private var terrainPreviewGeneration = 0
    private var mapCommandGeneration = 0
    private var mapCommandTask: Task<GeometryCulvertMapCommandPreviewResponse, Error>?
    private var mapCommandCommand: GeometryCulvertMapCommand?
    private var mapCommandSelectionIDs: [String] = []
    private var mapCommandOutputDraftIDCandidates: [String] = []
    private var mapCommandRequestIdentity: String?
    private var mapCommandRequestRevision: String?
    private var mapCommandRequestDraftState: String?
    private var mapCommandRequestDependencyRevision: String?
    private var smartAddSketchGeneration = 0
    private var smartAddPreviewGeneration = 0
    private var smartAddPreviewTask: Task<GeometryCulvertSmartAddPreviewResponse, Error>?
    private var smartAddFinishTask: Task<String?, Never>?
    private var smartAddContext: SmartAddSketchContext?
    private var smartAddPreviewCapture: GeometryCulvertSmartAddPreview?
    private var smartAddRequestedEndpoint: GeometryCulvertCoordinate?

    @Published private(set) var snapshot: GeometryCulvertSnapshot?
    @Published private(set) var selectedFeatureIDs: [String: Set<String>] = [
        "barrel": [], "barrelProperties": [], "openingProperties": []
    ] {
        didSet {
            if oldValue["barrel", default: []] != selectedFeatureIDs["barrel", default: []] {
                invalidateMapCommandPreview()
            }
        }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var isEditing = false
    @Published private(set) var parentSaveInProgress = false
    @Published private(set) var isProfileContextStale = false
    @Published private(set) var hasActiveSketch = false
    @Published private(set) var terrainPreview: GeometryCulvertTerrainPreview?
    @Published private(set) var isLoadingTerrainPreview = false
    @Published private(set) var terrainPreviewError: String?
    @Published private(set) var mapCommandPreview: GeometryCulvertMapCommandPreview?
    @Published private(set) var isLoadingMapCommandPreview = false
    @Published private(set) var mapCommandError: String?
    @Published private(set) var mapCommandNotice: String?
    @Published private(set) var smartAddSketchPoints: [GeometryCulvertCoordinate] = []
    @Published private(set) var smartAddPathPreview: [GeometryCulvertCoordinate]?
    @Published private(set) var isLoadingSmartAddPreview = false
    @Published private(set) var isFinishingSmartAdd = false
    @Published private(set) var smartAddError: String?
    @Published private(set) var smartAddNotice: String?
    @Published var smartAddOptions = GeometryCulvertSmartAddOptions() {
        didSet {
            if oldValue != smartAddOptions { invalidateSmartAddPreview() }
        }
    }
    @Published var error: String?

    init(provider: any GeometryCulvertProvider,
         onParentDraftChange: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.provider = provider
        self.onParentDraftChange = onParentDraftChange
    }

    var canEdit: Bool { snapshot?.canEdit == true && !parentSaveInProgress && !isEditing && !isProfileContextStale }
    var isDirty: Bool { snapshot?.isDirty == true }
    var canBeginParentSave: Bool { !isLoading && !isEditing && !parentSaveInProgress && !hasActiveSketch }
    var geometryCulvertStateForParentSave: String? { isDirty ? snapshot?.draftState : nil }
    var profileSamples: [ChartSample] {
        guard let snapshot else { return [] }
        return snapshot.profiles.flatMap { profile in
            profile.samples.map { sample in
                ChartSample(id: profile.barrelID + ":" + sample.id, x: sample.distance, y: sample.elevation,
                    series: snapshot.associatedTerrainName ?? "Terrain", datasetID: profile.barrelID)
            }
        }
    }
    var geometryCulvertIdentity: String {
        let projectContext = (currentModel?.projectPath ?? "") + "\n" + (currentModel?.projectXml ?? "")
        let projectRevision = SHA256.hash(data: Data(projectContext.utf8)).map { String(format: "%02x", $0) }.joined()
        return (currentAsset?.id ?? "") + "|" + (currentModel?.assetPath ?? "") + "|"
            + (snapshot?.revision ?? expectedSourceRevision ?? "") + "|" + projectRevision
    }
    var selectionDraftContextIdentity: String {
        geometryCulvertIdentity + "|" + (snapshot?.draftState ?? "")
            + "|" + (isProfileContextStale ? "stale" : "current")
    }
    var terrainPreviewIdentity: String {
        geometryCulvertIdentity + "|" + (snapshot?.dependencyRevision ?? "")
    }
    var canApplyMapCommandPreview: Bool {
        guard canEdit, !isLoading, !isLoadingMapCommandPreview, !hasActiveSketch,
              let preview = mapCommandPreview, let command = mapCommandCommand,
              let current = snapshot else { return false }
        let currentIDs = selectedFeatureIDs["barrel", default: []].sorted()
        let currentRowIDs = Set(current.barrels.rows.map(\.id))
        let requestedIDs = Set(command.requestedFeatureIDs)
        let commandSelectionMatches = mapCommandSelectionMatches(command,
            selectedIDs: Set(mapCommandSelectionIDs))
        let responseOutputIDs = preview.outputs.map(\.draftID)
        let outputIDsMatchRequest = responseOutputIDs.count <= mapCommandOutputDraftIDCandidates.count
            && responseOutputIDs == Array(mapCommandOutputDraftIDCandidates.prefix(responseOutputIDs.count))
        let targetIsCurrent: Bool
        if case let .split(barrelID, _, _, _) = command {
            targetIsCurrent = currentRowIDs.contains(barrelID)
                && preview.capturedFeatureIDs.contains(barrelID)
        } else {
            targetIsCurrent = true
        }
        return preview.geometryIdentity == geometryCulvertIdentity
            && preview.revision == current.revision
            && preview.draftState == current.draftState
            && preview.dependencyRevision == (current.dependencyRevision ?? "")
            && mapCommandSelectionIDs == currentIDs
            && commandSelectionMatches
            && preview.operation == command.operation
            && !preview.capturedFeatureIDs.isEmpty
            && Set(preview.capturedFeatureIDs).count == preview.capturedFeatureIDs.count
            && preview.capturedFeatureIDs.allSatisfy(currentRowIDs.contains)
            && requestedIDs.isSubset(of: Set(preview.capturedFeatureIDs))
            && Set(preview.removedFeatureIDs).count == preview.removedFeatureIDs.count
            && Set(preview.retainedFeatureIDs).count == preview.retainedFeatureIDs.count
            && Set(preview.removedFeatureIDs).isSubset(of: Set(preview.capturedFeatureIDs))
            && Set(preview.retainedFeatureIDs).isSubset(of: Set(preview.capturedFeatureIDs))
            && Set(preview.removedFeatureIDs).isDisjoint(with: Set(preview.retainedFeatureIDs))
            && previewOutputsAreValid(preview.outputs)
            && outputIDsMatchRequest
            && targetIsCurrent && preview.hasChange && preview.canApply && preview.errorCode == nil
    }
    var canFinishSmartAddSketch: Bool {
        guard hasActiveSketch, !isFinishingSmartAdd, !isLoading, !isLoadingSmartAddPreview, canEdit,
              smartAddSketchPoints.count >= 2, smartAddContextIsCurrent else { return false }
        return Self.hasUsablePolyline(smartAddSketchPoints)
    }

    private struct SmartAddSketchContext {
        let geometryIdentity: String
        let model: GeometryCulvertModelRequest
        let revision: String
        let draftState: String
        let dependencyRevision: String
        let generation: Int
    }

    private var smartAddContextIsCurrent: Bool {
        guard let context = smartAddContext, let current = snapshot, hasActiveSketch,
              context.generation == smartAddSketchGeneration,
              context.geometryIdentity == geometryCulvertIdentity,
              context.model == currentModel,
              context.revision == current.revision,
              context.draftState == current.draftState,
              context.dependencyRevision == current.dependencyRevision,
              !isProfileContextStale else { return false }
        return true
    }

    private static func isFinite(_ coordinate: GeometryCulvertCoordinate) -> Bool {
        coordinate.x.isFinite && coordinate.y.isFinite
    }

    private static func sameMapPoint(_ lhs: GeometryCulvertCoordinate,
                                     _ rhs: GeometryCulvertCoordinate) -> Bool {
        lhs.x == rhs.x && lhs.y == rhs.y
    }

    private static func hasUsablePolyline(_ points: [GeometryCulvertCoordinate]) -> Bool {
        guard points.count >= 2, points.allSatisfy({ isFinite($0) }) else { return false }
        return zip(points, points.dropFirst()).contains { pair in
            !sameMapPoint(pair.0, pair.1)
        }
    }

    private func mapCommandSelectionMatches(_ command: GeometryCulvertMapCommand,
                                            selectedIDs: Set<String>) -> Bool {
        switch command {
        case let .split(barrelID, _, _, _), let .offset(barrelID, _, _, _, _):
            selectedIDs == [barrelID]
        case let .merge(barrelIDs, _):
            selectedIDs == Set(barrelIDs)
        }
    }

    private func previewOutputsAreValid(_ outputs: [GeometryCulvertMapCommandOutput]) -> Bool {
        guard !outputs.isEmpty else { return false }
        let draftIDs = outputs.map(\.draftID)
        guard Set(draftIDs).count == draftIDs.count,
              draftIDs.allSatisfy(Self.isValidDraftID) else { return false }
        return outputs.allSatisfy { output in
            Self.hasUsablePolyline(output.polyline)
        }
    }

    private static func isValidDraftID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private func invalidateMapCommandPreview() {
        guard mapCommandPreview != nil || mapCommandTask != nil || isLoadingMapCommandPreview
            || mapCommandCommand != nil else { return }
        mapCommandGeneration += 1
        mapCommandTask?.cancel()
        mapCommandTask = nil
        mapCommandPreview = nil
        mapCommandCommand = nil
        mapCommandSelectionIDs = []
        mapCommandOutputDraftIDCandidates = []
        mapCommandRequestIdentity = nil
        mapCommandRequestRevision = nil
        mapCommandRequestDraftState = nil
        mapCommandRequestDependencyRevision = nil
        isLoadingMapCommandPreview = false
        mapCommandError = nil
        mapCommandNotice = nil
    }

    private func invalidateStaleMapCommandPreview() {
        guard let current = snapshot else {
            if mapCommandTask != nil || mapCommandPreview != nil { invalidateMapCommandPreview() }
            return
        }
        let currentRowIDs = Set(current.barrels.rows.map(\.id))
        let selectionIsCurrent = mapCommandSelectionIDs == selectedFeatureIDs["barrel", default: []].sorted()
        let requestIsCurrent = mapCommandTask == nil || (mapCommandRequestIdentity == geometryCulvertIdentity
            && mapCommandRequestRevision == current.revision
            && mapCommandRequestDraftState == current.draftState
            && mapCommandRequestDependencyRevision == (current.dependencyRevision ?? "")
            && selectionIsCurrent)
        let previewIsCurrent = mapCommandPreview.map { preview in
            preview.geometryIdentity == geometryCulvertIdentity
                && preview.revision == current.revision
                && preview.draftState == current.draftState
                && preview.dependencyRevision == (current.dependencyRevision ?? "")
                && selectionIsCurrent
                && preview.capturedFeatureIDs.allSatisfy(currentRowIDs.contains)
        } ?? true
        guard requestIsCurrent, previewIsCurrent else {
            invalidateMapCommandPreview()
            return
        }
    }

    private func invalidateSmartAddPreview() {
        guard smartAddPreviewCapture != nil || smartAddPreviewTask != nil
            || isLoadingSmartAddPreview || smartAddPathPreview != nil else { return }
        smartAddPreviewGeneration += 1
        smartAddPreviewTask?.cancel()
        smartAddPreviewTask = nil
        smartAddPreviewCapture = nil
        smartAddRequestedEndpoint = nil
        smartAddPathPreview = nil
        isLoadingSmartAddPreview = false
        smartAddError = nil
    }

    private func clearSmartAddSketchState() {
        smartAddSketchGeneration += 1
        smartAddPreviewGeneration += 1
        smartAddPreviewTask?.cancel()
        smartAddPreviewTask = nil
        smartAddFinishTask?.cancel()
        smartAddFinishTask = nil
        smartAddContext = nil
        smartAddPreviewCapture = nil
        smartAddRequestedEndpoint = nil
        smartAddSketchPoints = []
        smartAddPathPreview = nil
        isLoadingSmartAddPreview = false
        isFinishingSmartAdd = false
        smartAddError = nil
        smartAddNotice = nil
    }

    private func smartAddOptionsAreValid(_ options: GeometryCulvertSmartAddOptions) -> Bool {
        (options.algorithm == "HessianRidgeness" || options.algorithm == "HighGround")
            && options.dpTolerancePixels.isFinite && options.dpTolerancePixels >= 0
            && options.maxSegmentPixels.isFinite && options.maxSegmentPixels > 0
            && options.previewThrottlePixels.isFinite && options.previewThrottlePixels > 0
            && options.highGroundAlpha.isFinite && options.highGroundAlpha >= 0
            && options.highGroundBailRatio.isFinite && options.highGroundBailRatio > 0
            && options.highGroundSnapRadiusCells >= 0
            && options.hessianFrangiBeta.isFinite && options.hessianFrangiBeta > 0
            && options.hessianFeaturePenaltyKappa.isFinite && options.hessianFeaturePenaltyKappa >= 0
            && options.hessianOffFeatureBailMultiplier.isFinite && options.hessianOffFeatureBailMultiplier > 0
            && options.hessianMinExpansionsBudget > 0
            && options.hessianExpansionsPerEuclidPx > 0
            && options.hessianMaxEuclidCells > 0
    }

    /// Invalidates outstanding work before the parent switches model or starts
    /// a fresh editor draft.
    func invalidate() {
        guard !hasActiveSketch else {
            error = L10n.text("Finish or cancel the active culvert map preview before changing the geometry.")
            return
        }
        invalidateMapCommandPreview()
        clearSmartAddSketchState()
        loadGeneration += 1
        modelGeneration += 1
        terrainPreviewGeneration += 1
        let hadDraft = isDirty
        currentAsset = nil
        currentModel = nil
        expectedSourceRevision = nil
        didLoad = false
        activeParentSaveID = nil
        pendingSketchContext = nil
        snapshot = nil
        terrainPreview = nil
        terrainPreviewError = nil
        isLoadingTerrainPreview = false
        selectedFeatureIDs = ["barrel": [], "barrelProperties": [], "openingProperties": []]
        isLoading = false
        isEditing = false
        parentSaveInProgress = false
        isProfileContextStale = false
        hasActiveSketch = false
        error = nil
        if hadDraft { onParentDraftChange(false) }
    }

    func ensureLoaded(asset: ProjectAsset, sourceRevision: String?) async {
        guard !parentSaveInProgress else { return }
        guard asset.section == .geometries else {
            error = L10n.text("Culvert editing requires a geometry asset.")
            return
        }
        let model = provider.modelRequest(for: asset)
        if hasActiveSketch,
           (currentAsset?.id != asset.id || currentModel != model || expectedSourceRevision != sourceRevision) {
            pendingSketchContext = (asset, sourceRevision)
            isProfileContextStale = true
            if smartAddContext != nil {
                invalidateSmartAddPreview()
                smartAddError = L10n.text("The geometry or associated terrain changed during Smart Add. Cancel this sketch before continuing.")
            }
            error = L10n.text("Finish or cancel the active culvert map preview before changing its source context.")
            return
        }
        let sameAsset = currentAsset?.id == asset.id
            && currentModel?.assetPath == model.assetPath
            && currentModel?.kind == model.kind
        if currentAsset != nil && !sameAsset {
            if isDirty {
                isProfileContextStale = true
                error = L10n.text("The geometry changed while culvert edits are pending. Discard the culvert draft before switching assets.")
                return
            }
            invalidate()
        }
        // Project XML is allowed to change while a culvert draft is open. The
        // backend binds that draft to the actual Geometry-to-Terrain selection
        // and terrain file dependencies, so it can safely replay an unrelated
        // project edit and reject a changed profile context without discarding
        // the user's mutations.
        if didLoad, currentModel == model, expectedSourceRevision == sourceRevision { return }
        if isDirty && expectedSourceRevision != sourceRevision {
            isProfileContextStale = true
            invalidateMapCommandPreview()
            error = L10n.text("The geometry source changed while culvert edits are pending. Save or discard the culvert draft before reloading.")
            return
        }
        currentAsset = asset
        currentModel = model
        expectedSourceRevision = sourceRevision
        await fetch(model: model, expectedRevision: sourceRevision, asset: asset,
            draftState: isDirty ? snapshot?.draftState : nil)
    }

    func reload() async {
        guard !hasActiveSketch else { return }
        guard let model = currentModel, let asset = currentAsset else { return }
        await fetch(model: model, expectedRevision: expectedSourceRevision, asset: asset,
            draftState: isDirty ? snapshot?.draftState : nil)
    }

    /// Loads the associated terrain image through the retained source raster
    /// renderer. The response is tied to the current geometry, project XML,
    /// terrain inputs and HDF revision so an old preview cannot replace a new
    /// association's basemap.
    func loadTerrainPreview() async {
        guard let provider = provider as? any GeometryCulvertTerrainPreviewProviding,
              let model = currentModel, let assetID = currentAsset?.id,
              let current = snapshot else {
            terrainPreview = nil
            terrainPreviewError = nil
            return
        }
        let expectedDependencyRevision = current.dependencyRevision
        if terrainPreview?.dependencyRevision == expectedDependencyRevision,
           expectedDependencyRevision != nil { return }

        terrainPreviewGeneration += 1
        let generation = terrainPreviewGeneration
        let requestIdentity = geometryCulvertIdentity
        isLoadingTerrainPreview = true
        terrainPreviewError = nil
        defer {
            if generation == terrainPreviewGeneration { isLoadingTerrainPreview = false }
        }
        do {
            let loaded = try await provider.terrainPreview(model,
                expectedDependencyRevision: expectedDependencyRevision)
            guard generation == terrainPreviewGeneration, currentAsset?.id == assetID,
                  currentModel == model, geometryCulvertIdentity == requestIdentity,
                  snapshot?.dependencyRevision == loaded.dependencyRevision,
                  !Task.isCancelled else { return }
            terrainPreview = loaded
        } catch {
            guard generation == terrainPreviewGeneration, currentAsset?.id == assetID,
                  currentModel == model, geometryCulvertIdentity == requestIdentity,
                  !Task.isCancelled else { return }
            terrainPreview = nil
            terrainPreviewError = error.localizedDescription
        }
    }

    @discardableResult
    func previewMapCommand(_ command: GeometryCulvertMapCommand) async -> Bool {
        invalidateMapCommandPreview()
        guard canEdit, !hasActiveSketch, didLoad, let current = snapshot,
              let model = currentModel, currentAsset != nil else {
            mapCommandError = L10n.text("Load an editable geometry before previewing a culvert map command.")
            return false
        }
        guard let mapProvider = provider as? any GeometryCulvertMapCommandProviding else {
            mapCommandError = L10n.text("Culvert map command previews are unavailable from the current provider.")
            return false
        }
        guard mapCommandParametersAreValid(command) else {
            mapCommandError = L10n.text("Enter valid culvert map command parameters and select the required barrel rows.")
            return false
        }

        mapCommandGeneration += 1
        let generation = mapCommandGeneration
        let assetID = currentAsset?.id
        let requestIdentity = geometryCulvertIdentity
        let requestRevision = current.revision
        let requestDraftState = current.draftState
        let requestDependencyRevision = current.dependencyRevision ?? ""
        let requestSelectionIDs = selectedFeatureIDs["barrel", default: []].sorted()
        let previewID = UUID().uuidString
        let request = command.previewRequest(model: model, revision: requestRevision,
            draftState: requestDraftState, previewID: previewID,
            availableBarrelCount: current.barrels.rows.count)
        let task = Task { try await mapProvider.previewMapCommand(request) }
        mapCommandTask = task
        mapCommandCommand = command
        mapCommandSelectionIDs = requestSelectionIDs
        mapCommandOutputDraftIDCandidates = request.outputDraftIDs ?? []
        mapCommandRequestIdentity = requestIdentity
        mapCommandRequestRevision = requestRevision
        mapCommandRequestDraftState = requestDraftState
        mapCommandRequestDependencyRevision = requestDependencyRevision
        isLoadingMapCommandPreview = true
        mapCommandError = nil
        mapCommandNotice = nil
        defer {
            if generation == mapCommandGeneration {
                isLoadingMapCommandPreview = false
                mapCommandTask = nil
            }
        }
        do {
            let response = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard generation == mapCommandGeneration, currentAsset?.id == assetID,
                  currentModel == model, geometryCulvertIdentity == requestIdentity,
                  snapshot?.revision == requestRevision, snapshot?.draftState == requestDraftState,
                  (snapshot?.dependencyRevision ?? "") == requestDependencyRevision,
                  selectedFeatureIDs["barrel", default: []].sorted() == requestSelectionIDs,
                  !Task.isCancelled else { return false }
            guard response.previewID == previewID, response.operation == command.operation,
                  response.revision == requestRevision, response.draftState == requestDraftState,
                  response.dependencyRevision == requestDependencyRevision else {
                mapCommandPreview = nil
                mapCommandError = L10n.text("The culvert map preview returned for an older geometry or terrain revision.")
                return false
            }
            let preview = GeometryCulvertMapCommandPreview(response: response,
                geometryIdentity: requestIdentity)
            mapCommandPreview = preview
            if let code = response.errorCode {
                mapCommandError = mapCommandErrorMessage(code)
            }
            if let warning = response.warningCode {
                mapCommandNotice = mapCommandWarningMessage(warning)
            } else if !response.hasChange {
                mapCommandNotice = L10n.text("This culvert map command preview has no changes to apply.")
            }
            // A validated response is no longer in flight. Clear this before
            // evaluating canApplyMapCommandPreview, which correctly rejects
            // edits while the provider request is still pending.
            isLoadingMapCommandPreview = false
            return canApplyMapCommandPreview
        } catch {
            guard generation == mapCommandGeneration else { return false }
            if Task.isCancelled {
                invalidateMapCommandPreview()
                return false
            }
            mapCommandPreview = nil
            mapCommandError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func applyMapCommandPreview() async -> Bool {
        guard canApplyMapCommandPreview,
              let command = mapCommandCommand,
              let preview = mapCommandPreview else {
            mapCommandError = L10n.text("The culvert map preview is stale or does not produce an applicable change.")
            return false
        }
        let notice = preview.warningCode.map(mapCommandWarningMessage)
            ?? (preview.outputs.isEmpty ? nil
                : L10n.text("Generated culvert barrel rows use the source default hydraulic properties."))
        let mutation = command.mutation(preview: preview)
        invalidateMapCommandPreview()
        mapCommandError = nil
        let applied = await submit(mutation)
        if applied {
            mapCommandNotice = notice
        } else {
            mapCommandError = error ?? L10n.text("The culvert map command could not be applied to the current draft.")
        }
        return applied
    }

    func cancelMapCommandPreview() {
        invalidateMapCommandPreview()
    }

    func beginSmartAddSketch(at anchor: GeometryCulvertCoordinate) {
        guard canEdit, !hasActiveSketch, didLoad,
              let current = snapshot, let model = currentModel,
              currentAsset != nil, current.associatedTerrainName != nil,
              let dependencyRevision = current.dependencyRevision, !dependencyRevision.isEmpty else {
            smartAddError = L10n.text("Smart Add needs a loaded editable geometry with an associated terrain.")
            return
        }
        guard mapCommandPreview == nil, !isLoadingMapCommandPreview else {
            smartAddError = L10n.text("Finish or cancel the active culvert map preview before changing the geometry.")
            return
        }
        guard Self.isFinite(anchor) else {
            smartAddError = L10n.text("Choose a finite map coordinate to start Smart Add.")
            return
        }
        guard smartAddOptionsAreValid(smartAddOptions) else {
            smartAddError = L10n.text("The Smart Add options contain an unsupported algorithm or invalid value.")
            return
        }
        smartAddSketchGeneration += 1
        smartAddPreviewGeneration += 1
        smartAddPreviewTask?.cancel()
        smartAddPreviewTask = nil
        smartAddContext = SmartAddSketchContext(geometryIdentity: geometryCulvertIdentity,
            model: model, revision: current.revision, draftState: current.draftState,
            dependencyRevision: dependencyRevision, generation: smartAddSketchGeneration)
        smartAddSketchPoints = [anchor]
        smartAddPreviewCapture = nil
        smartAddRequestedEndpoint = nil
        smartAddPathPreview = nil
        isLoadingSmartAddPreview = false
        isFinishingSmartAdd = false
        smartAddError = nil
        smartAddNotice = nil
        setSketchActive(true)
    }

    @discardableResult
    func previewSmartAddSegment(from start: GeometryCulvertCoordinate,
                                to end: GeometryCulvertCoordinate,
                                window: GeometryCulvertSmartAddWindow) async -> Bool {
        // A queued hover callback after Finish/Cancel must be a silent no-op.
        guard hasActiveSketch, smartAddContext != nil else { return false }
        guard smartAddContextIsCurrent, let context = smartAddContext,
              let lastPoint = smartAddSketchPoints.last else {
            invalidateSmartAddPreview()
            smartAddError = L10n.text("The geometry or associated terrain changed during Smart Add. Cancel this sketch before continuing.")
            return false
        }
        guard Self.sameMapPoint(start, lastPoint) else {
            invalidateSmartAddPreview()
            smartAddError = L10n.text("The Smart Add segment no longer starts at the current sketch endpoint.")
            return false
        }
        guard let mapProvider = provider as? any GeometryCulvertMapCommandProviding else {
            invalidateSmartAddPreview()
            smartAddError = L10n.text("Smart Add terrain path previews are unavailable from the current provider.")
            return false
        }
        guard Self.isFinite(start), Self.isFinite(end), smartAddWindowIsValid(window),
              smartAddOptionsAreValid(smartAddOptions) else {
            invalidateSmartAddPreview()
            smartAddError = L10n.text("Smart Add needs finite endpoints, a valid raster window, and valid options.")
            return false
        }

        invalidateSmartAddPreview()
        smartAddPreviewGeneration += 1
        let previewGeneration = smartAddPreviewGeneration
        let sketchGeneration = context.generation
        let requestedIdentity = context.geometryIdentity
        let previewID = UUID().uuidString
        smartAddRequestedEndpoint = end
        let options = smartAddOptions
        let request = GeometryCulvertSmartAddPreviewRequest(model: context.model,
            revision: context.revision, draftState: context.draftState, previewID: previewID,
            start: start, end: end, window: window, options: options)
        let task = Task { try await mapProvider.previewSmartAdd(request) }
        smartAddPreviewTask = task
        isLoadingSmartAddPreview = true
        smartAddError = nil
        defer {
            if previewGeneration == smartAddPreviewGeneration {
                isLoadingSmartAddPreview = false
                smartAddPreviewTask = nil
            }
        }
        do {
            let response = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard previewGeneration == smartAddPreviewGeneration,
                  sketchGeneration == smartAddSketchGeneration,
                  smartAddContextIsCurrent,
                  smartAddRequestedEndpoint.map({ Self.sameMapPoint($0, end) }) == true,
                  Self.sameMapPoint(smartAddSketchPoints.last ?? start, start),
                  smartAddOptions == options, !Task.isCancelled else { return false }
            guard response.previewID == previewID,
                  response.revision == context.revision,
                  response.draftState == context.draftState,
                  response.dependencyRevision == context.dependencyRevision else {
                smartAddError = L10n.text("The Smart Add path preview belongs to an older geometry or terrain revision.")
                return false
            }
            let preview = GeometryCulvertSmartAddPreview(response: response,
                geometryIdentity: requestedIdentity, start: start, end: end,
                window: window, options: options)
            smartAddPreviewCapture = preview
            guard response.canAppend, response.path.count >= 2,
                  response.path.allSatisfy({ Self.isFinite($0) }),
                  Self.sameMapPoint(response.path[0], start) else {
                smartAddPathPreview = nil
                smartAddError = response.errorCode.map(smartAddErrorMessage)
                    ?? L10n.text("The terrain service did not produce a usable Smart Add path for this segment.")
                return false
            }
            smartAddPathPreview = response.path
            if let code = response.errorCode { smartAddError = smartAddErrorMessage(code) }
            return response.errorCode == nil
        } catch {
            guard previewGeneration == smartAddPreviewGeneration,
                  sketchGeneration == smartAddSketchGeneration else { return false }
            if Task.isCancelled {
                invalidateSmartAddPreview()
                return false
            }
            smartAddPreviewCapture = nil
            smartAddPathPreview = nil
            smartAddError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func acceptSmartAddSegment() -> Bool {
        guard smartAddContextIsCurrent, !isLoadingSmartAddPreview,
              let preview = smartAddPreviewCapture,
              preview.canAppend, preview.errorCode == nil,
              preview.geometryIdentity == geometryCulvertIdentity,
              preview.revision == snapshot?.revision,
              preview.draftState == snapshot?.draftState,
              preview.dependencyRevision == snapshot?.dependencyRevision,
              smartAddRequestedEndpoint.map({ Self.sameMapPoint($0, preview.end) }) == true,
              let lastPoint = smartAddSketchPoints.last,
              Self.sameMapPoint(lastPoint, preview.start),
              preview.path.count >= 2,
              preview.path.allSatisfy({ Self.isFinite($0) }),
              Self.sameMapPoint(preview.path[0], preview.start) else {
            smartAddError = L10n.text("The Smart Add path preview is stale or does not match the current endpoints.")
            return false
        }
        let updated = smartAddSketchPoints + Array(preview.path.dropFirst())
        guard Self.hasUsablePolyline(updated) else {
            smartAddError = L10n.text("The Smart Add path does not add a distinct point to the sketch.")
            return false
        }
        smartAddPreviewTask?.cancel()
        smartAddPreviewTask = nil
        smartAddPreviewGeneration += 1
        smartAddPreviewCapture = nil
        smartAddRequestedEndpoint = nil
        smartAddPathPreview = nil
        isLoadingSmartAddPreview = false
        smartAddSketchPoints = updated
        smartAddError = nil
        return true
    }

    @discardableResult
    func finishSmartAddSketch() async -> String? {
        guard canFinishSmartAddSketch, let context = smartAddContext else {
            smartAddError = L10n.text("Smart Add needs a current terrain path with at least two distinct points before it can finish.")
            return nil
        }
        let generation = context.generation
        let points = smartAddSketchPoints
        isFinishingSmartAdd = true
        smartAddError = nil
        let task = Task<String?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.addBarrel(points: points)
        }
        smartAddFinishTask = task
        // Once the final addBarrel request starts, keep its result so the local
        // child ledger can reconcile with the backend. The UI disables Cancel
        // while this one write is in flight; previews remain cancellable.
        let barrelID = await task.value
        guard generation == smartAddSketchGeneration else { return nil }
        smartAddFinishTask = nil
        isFinishingSmartAdd = false
        guard let barrelID,
              snapshot?.barrels.rows.contains(where: { $0.id == barrelID }) == true else {
            smartAddError = error ?? L10n.text("The Smart Add barrel could not be added to the geometry draft.")
            return nil
        }
        smartAddSketchGeneration += 1
        smartAddPreviewGeneration += 1
        smartAddPreviewTask?.cancel()
        smartAddPreviewTask = nil
        smartAddContext = nil
        smartAddPreviewCapture = nil
        smartAddRequestedEndpoint = nil
        smartAddSketchPoints = []
        smartAddPathPreview = nil
        isLoadingSmartAddPreview = false
        smartAddError = nil
        smartAddNotice = L10n.text("The generated culvert barrel uses the source default hydraulic properties.")
        setSketchActive(false)
        return barrelID
    }

    func cancelSmartAddSketch() {
        guard smartAddContext != nil, !isFinishingSmartAdd else { return }
        clearSmartAddSketchState()
        setSketchActive(false)
    }

    private func mapCommandParametersAreValid(_ command: GeometryCulvertMapCommand) -> Bool {
        guard didLoad, let current = snapshot else { return false }
        let rowIDs = Set(current.barrels.rows.map(\.id))
        let selectedIDs = selectedFeatureIDs["barrel", default: []]
        switch command {
        case let .split(barrelID, coordinate, _, mapCellSize):
            return !barrelID.isEmpty && rowIDs.contains(barrelID) && selectedIDs == [barrelID]
                && Self.isFinite(coordinate)
                && mapCellSize.isFinite && mapCellSize > 0
        case let .merge(barrelIDs, tolerance):
            return Set(barrelIDs).count >= 2 && Set(barrelIDs).count == barrelIDs.count
                && Set(barrelIDs) == selectedIDs
                && Set(barrelIDs).isSubset(of: rowIDs) && !barrelIDs.contains(where: { $0.isEmpty })
                && tolerance.isFinite && tolerance >= 0
        case let .offset(barrelID, distance, _, _, _):
            return !barrelID.isEmpty && rowIDs.contains(barrelID) && selectedIDs == [barrelID]
                && distance.isFinite && distance > 0
        }
    }

    private func smartAddWindowIsValid(_ window: GeometryCulvertSmartAddWindow) -> Bool {
        let extent = window.extent
        guard window.rows >= 2, window.columns >= 2,
              window.rows <= 8_000_000 / window.columns,
              extent.minX.isFinite, extent.minY.isFinite,
              extent.maxX.isFinite, extent.maxY.isFinite else { return false }
        return extent.maxX > extent.minX && extent.maxY > extent.minY
    }

    private func mapCommandErrorMessage(_ code: String) -> String {
        switch code {
        case "splitNoSnap":
            L10n.text("No barrel segment was hit at the split point.")
        case "targetMismatch":
            L10n.text("The clicked barrel is not among the source split hits.")
        case "splitProducesInvalidLine":
            L10n.text("The split point would create an invalid barrel line.")
        case "mergeNoConnectedLines":
            L10n.text("The selected barrels cannot be merged at this tolerance.")
        case "offsetUnavailable":
            L10n.text("The source offset operation could not create a valid barrel line.")
        default:
            L10n.text("The source could not preview this culvert map command.")
        }
    }

    private func mapCommandWarningMessage(_ code: String) -> String {
        switch code {
        case "generatedBarrelsRequireProperties":
            L10n.text("Generated culvert barrel rows use the source default hydraulic properties.")
        default:
            L10n.text("Review the source warning before applying the culvert map command.")
        }
    }

    private func smartAddErrorMessage(_ code: String) -> String {
        switch code {
        case "associatedTerrainUnavailable":
            L10n.text("This geometry has no usable associated terrain for Smart Add.")
        case "invalidOptions":
            L10n.text("The Smart Add options are not valid for the source path finder.")
        case "invalidRasterWindow":
            L10n.text("The visible terrain window is not a valid raster sampling area.")
        case "invalidEndpoint":
            L10n.text("The Smart Add segment endpoints must be finite map coordinates.")
        case "segmentTooLong":
            L10n.text("The Smart Add segment exceeds the source maximum pixel length.")
        case "segmentTooShort":
            L10n.text("The Smart Add segment is too short to create a path.")
        case "terrainSamplingUnavailable":
            L10n.text("The associated terrain has no valid samples in this window.")
        case "pathUnavailable":
            L10n.text("The source terrain path finder could not connect these points.")
        default:
            L10n.text("The source terrain path preview could not be completed.")
        }
    }

    func table(for featureKind: String) -> GeometryCulvertFeatureTable {
        let table: GeometryCulvertFeatureTable?
        switch featureKind {
        case "barrel": table = snapshot?.barrels
        case "barrelProperties": table = snapshot?.barrelProperties
        case "openingProperties": table = snapshot?.openingProperties
        default: table = nil
        }
        return table ?? GeometryCulvertFeatureTable(featureKind: featureKind, columns: [], editableFields: [], rows: [])
    }

    func selectedRows(for featureKind: String) -> [GeometryCulvertFeatureRow] {
        let selected = selectedFeatureIDs[featureKind, default: []]
        return table(for: featureKind).rows.filter { selected.contains($0.id) }
    }

    /// The source OpeningPropertiesDetailEditor exposes its clear command only
    /// when the selected property sets disagree on this coefficient.
    func openingCoefficientHasMismatch(fieldID: String) -> Bool {
        guard fieldID == "KIn" || fieldID == "KOut" else { return false }
        return fieldHasMismatch(featureKind: "openingProperties", fieldID: fieldID)
    }

    func fieldHasMismatch(featureKind: String, fieldID: String) -> Bool {
        let values = selectedRows(for: featureKind).map { $0.values[fieldID] ?? "" }
        return values.count > 1 && Set(values).count > 1
    }

    func select(_ ids: Set<String>, featureKind: String) async {
        guard ["barrel", "barrelProperties", "openingProperties"].contains(featureKind),
              !parentSaveInProgress, !isEditing else { return }
        selectedFeatureIDs[featureKind] = ids
        guard featureKind == "barrel", let model = currentModel, let asset = currentAsset,
              let current = snapshot, didLoad else { return }
        await fetch(model: model, expectedRevision: current.revision, asset: asset,
            draftState: current.draftState)
    }

    func setField(featureKind: String, fieldID: String, value: String) async {
        let selectedIDs = selectedFeatureIDs[featureKind, default: []]
        _ = await setField(featureKind: featureKind, fieldID: fieldID, value: value,
            expectedSelectedIDs: selectedIDs, expectedContextIdentity: selectionDraftContextIdentity)
    }

    @discardableResult
    func setField(featureKind: String, fieldID: String, value: String,
                  expectedSelectedIDs: Set<String>, expectedContextIdentity: String) async -> Bool {
        guard canEdit, !isLoading, !hasActiveSketch,
              ["barrel", "barrelProperties", "openingProperties"].contains(featureKind),
              !expectedSelectedIDs.isEmpty,
              selectedFeatureIDs[featureKind, default: []] == expectedSelectedIDs,
              selectionDraftContextIdentity == expectedContextIdentity else { return false }
        let ids = expectedSelectedIDs.sorted()
        return await submit(GeometryCulvertMutation(operation: "setField", featureKind: featureKind,
            featureIDs: ids, fieldID: fieldID, value: value))
    }

    /// Executes the source ComboBox ForceSetCommand through the undoable
    /// geometry draft ledger. It is deliberately available only for the
    /// source field that advertises the command and only while its selection
    /// still has mixed values.
    @discardableResult
    func forceSetChoice(_ field: GeometryCulvertField, value: String) async -> Bool {
        guard canEdit, !isLoading, !hasActiveSketch,
              field.id == "OpeningType", field.forceSetCommand == "forceSetOpeningType",
              field.choices.contains(value), fieldHasMismatch(featureKind: "openingProperties", fieldID: field.id) else {
            return false
        }
        let ids = selectedFeatureIDs["openingProperties", default: []].sorted()
        guard !ids.isEmpty else { return false }
        return await submit(GeometryCulvertMutation(operation: field.forceSetCommand!,
            featureKind: "openingProperties", featureIDs: ids, fieldID: field.id, value: value))
    }

    /// Applies the source ForceResetKIn/ForceResetKOut operation to the exact
    /// stable row IDs currently selected in the Opening Properties table.
    /// The backend writes NaN through ObservableOpeningProperties while this
    /// draft remains staged for the parent geometry save/discard flow.
    @discardableResult
    func resetSelectedOpeningCoefficient(fieldID: String) async -> Bool {
        guard canEdit, !isLoading, !hasActiveSketch,
              fieldID == "KIn" || fieldID == "KOut",
              openingCoefficientHasMismatch(fieldID: fieldID) else { return false }
        let ids = selectedFeatureIDs["openingProperties", default: []].sorted()
        guard !ids.isEmpty else { return false }
        return await submit(GeometryCulvertMutation(operation: "resetOpeningCoefficient",
            featureKind: "openingProperties", featureIDs: ids, fieldID: fieldID))
    }

    @discardableResult
    func addBarrel(points: [GeometryCulvertCoordinate]) async -> String? {
        guard canEdit else { return nil }
        let draftID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let barrelID = "barrel:draft:" + draftID
        let previousSelection = selectedFeatureIDs["barrel", default: []]
        selectedFeatureIDs["barrel"] = [barrelID]
        let added = await submit(GeometryCulvertMutation(operation: "addBarrel", featureKind: "barrel",
            featureIDs: [], draftID: draftID, polyline: points))
        guard added else {
            selectedFeatureIDs["barrel"] = previousSelection
            return nil
        }
        return barrelID
    }

    @discardableResult
    func setPolyline(id: String, points: [GeometryCulvertCoordinate]) async -> Bool {
        guard canEdit else { return false }
        return await submit(GeometryCulvertMutation(operation: "setPolyline", featureKind: "barrel",
            featureIDs: [id], polyline: points))
    }

    /// Applies the retained ReversePolylineHandler operation to exactly one
    /// selected barrel. The source Polyline.Reverse implementation reverses
    /// XY and its tracked Z/M arrays together; the row's other barrel fields
    /// and stable identity stay in place.
    @discardableResult
    func reverseBarrel(id: String) async -> Bool {
        guard canEdit, !hasActiveSketch, selectedBarrelRow(for: id) != nil else { return false }
        return await submit(GeometryCulvertMutation(operation: "reverseBarrel", featureKind: "barrel",
            featureIDs: [id]))
    }

    /// The retained FilterPolylineHandler builds an XY-only result. Keep the
    /// source's exact Douglas-Peucker parameter but refuse dimensional input
    /// so this native editor never silently drops Z/M values.
    @discardableResult
    func filterBarrel(id: String, tolerance: Double) async -> Bool {
        guard canEdit, !hasActiveSketch, tolerance.isFinite, tolerance > 0,
              let row = selectedBarrelRow(for: id), isXYOnly(row) else { return false }
        return await submit(GeometryCulvertMutation(operation: "filterBarrel", featureKind: "barrel",
            featureIDs: [id], tolerance: tolerance))
    }

    /// Uses the retained moving-average smoothing algorithm and parameters.
    /// Its output is XY-only, so a line with Z or M values is rejected.
    @discardableResult
    func smoothBarrel(id: String, windowSize: Int, passes: Int) async -> Bool {
        guard canEdit, !hasActiveSketch, windowSize >= 3, passes >= 1,
              let row = selectedBarrelRow(for: id), isXYOnly(row) else { return false }
        return await submit(GeometryCulvertMutation(operation: "smoothBarrel", featureKind: "barrel",
            featureIDs: [id], windowSize: windowSize, passes: passes))
    }

    func selectedBarrelSupportsXYOnlyGeoprocessing(id: String) -> Bool {
        guard let row = selectedBarrelRow(for: id) else { return false }
        return isXYOnly(row)
    }

    private func selectedBarrelRow(for id: String) -> GeometryCulvertFeatureRow? {
        guard selectedFeatureIDs["barrel", default: []] == [id] else { return nil }
        return snapshot?.barrels.rows.first { $0.id == id }
    }

    private func isXYOnly(_ row: GeometryCulvertFeatureRow) -> Bool {
        !row.polyline.contains { $0.z != nil || $0.m != nil }
    }

    func moveBarrels(ids: Set<String>, deltaX: Double, deltaY: Double) async -> Bool {
        guard canEdit, !ids.isEmpty, deltaX.isFinite, deltaY.isFinite,
              deltaX != 0 || deltaY != 0 else { return false }
        let previousSelection = selectedFeatureIDs["barrel", default: []]
        selectedFeatureIDs["barrel"] = ids
        let moved = await submit(GeometryCulvertMutation(operation: "moveBarrels", featureKind: "barrel",
            featureIDs: ids.sorted(), deltaX: deltaX, deltaY: deltaY))
        if !moved { selectedFeatureIDs["barrel"] = previousSelection }
        return moved
    }

    func copiedBarrels(for ids: Set<String>) -> [GeometryCulvertCopiedBarrel] {
        let byID = Dictionary(uniqueKeysWithValues: table(for: "barrel").rows.map { ($0.id, $0) })
        return ids.sorted().compactMap { id in
            guard let row = byID[id] else { return nil }
            return GeometryCulvertCopiedBarrel(draftID: "", name: row.values["Name"] ?? "",
                barrelPropertyName: row.values["BarrelPropertyName"] ?? "",
                upstreamInvert: row.values["UpstreamInvert"] ?? "NaN",
                downstreamInvert: row.values["DownstreamInvert"] ?? "NaN",
                upstreamOpeningName: row.values["UpstreamOpeningName"] ?? "",
                downstreamOpeningName: row.values["DownstreamOpeningName"] ?? "",
                polyline: row.polyline)
        }
    }

    @discardableResult
    func duplicateSelectedBarrels() async -> Bool {
        await pasteBarrels(copiedBarrels(for: selectedFeatureIDs["barrel", default: []]))
    }

    @discardableResult
    func pasteBarrels(_ copiedBarrels: [GeometryCulvertCopiedBarrel]) async -> Bool {
        guard canEdit, !hasActiveSketch, !copiedBarrels.isEmpty else { return false }
        let features = copiedBarrels.map { copied in
            GeometryCulvertCopiedBarrel(
                draftID: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                name: copied.name, barrelPropertyName: copied.barrelPropertyName,
                upstreamInvert: copied.upstreamInvert, downstreamInvert: copied.downstreamInvert,
                upstreamOpeningName: copied.upstreamOpeningName,
                downstreamOpeningName: copied.downstreamOpeningName, polyline: copied.polyline)
        }
        let previousSelection = selectedFeatureIDs["barrel", default: []]
        let newSelection = Set(features.map { "barrel:draft:" + $0.draftID })
        selectedFeatureIDs["barrel"] = newSelection
        let pasted = await submit(GeometryCulvertMutation(operation: "pasteBarrels", featureKind: "barrel",
            featureIDs: [], copiedBarrels: features))
        if !pasted { selectedFeatureIDs["barrel"] = previousSelection }
        return pasted
    }

    @discardableResult
    func undoLastEdit() async -> Bool {
        guard canEdit, isDirty, !hasActiveSketch else { return false }
        return await submit(GeometryCulvertMutation(operation: "undo", featureKind: "barrel", featureIDs: []))
    }

    func addPropertySet(featureKind: String) async {
        guard !hasActiveSketch else { return }
        guard featureKind == "barrelProperties" || featureKind == "openingProperties" else { return }
        let draftID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        await submit(GeometryCulvertMutation(operation: "add", featureKind: featureKind,
            featureIDs: [], draftID: draftID))
    }

    func deleteSelected(featureKind: String) async {
        guard !hasActiveSketch else { return }
        guard ["barrel", "barrelProperties", "openingProperties"].contains(featureKind) else { return }
        let ids = selectedFeatureIDs[featureKind, default: []].sorted()
        guard !ids.isEmpty else { return }
        await submit(GeometryCulvertMutation(operation: "delete", featureKind: featureKind, featureIDs: ids))
    }

    /// A nil return means this child is busy. The capture may have a nil
    /// draftState so ordinary geometry edits can save before this page loads.
    func beginParentSave() -> GeometryCulvertParentSaveCapture? {
        guard canBeginParentSave else { return nil }
        invalidateMapCommandPreview()
        let operationID = UUID()
        activeParentSaveID = operationID
        parentSaveInProgress = true
        return GeometryCulvertParentSaveCapture(operationID: operationID, generation: modelGeneration,
            assetID: currentAsset?.id, draftState: geometryCulvertStateForParentSave,
            sourceRevision: snapshot?.revision)
    }

    /// The parent HDF save has succeeded. Discard only the captured child
    /// draft, then re-read the new source revision.
    func acknowledgeParentSave(_ capture: GeometryCulvertParentSaveCapture, newSourceRevision: String?) async {
        guard parentCaptureIsCurrent(capture) else { return }
        guard let asset = currentAsset, let model = currentModel else {
            releaseParentSave(capture)
            return
        }
        guard geometryCulvertStateForParentSave == capture.draftState else {
            releaseParentSave(capture)
            return
        }
        let hadCapturedDraft = capture.draftState != nil
        expectedSourceRevision = newSourceRevision
        if hadCapturedDraft {
            onParentDraftChange(false)
            // Source feature IDs include row positions. A committed map edit
            // may reindex retained features, so intersecting the previous
            // selection with the newly loaded IDs could select another row.
            selectedFeatureIDs = ["barrel": [], "barrelProperties": [], "openingProperties": []]
        }
        didLoad = false
        await fetch(model: model, expectedRevision: newSourceRevision, asset: asset, draftState: nil)
        releaseParentSave(capture)
    }

    func parentSaveFailed(_ capture: GeometryCulvertParentSaveCapture) {
        guard parentCaptureIsCurrent(capture) else { return }
        releaseParentSave(capture)
    }

    func discardDraft() async {
        guard !parentSaveInProgress else { return }
        guard !hasActiveSketch else {
            error = L10n.text("Cancel the active culvert map preview before discarding culvert edits.")
            return
        }
        invalidateMapCommandPreview()
        let hadDraft = isDirty
        loadGeneration += 1
        isEditing = false
        isLoading = false
        didLoad = false
        snapshot = nil
        expectedSourceRevision = nil
        selectedFeatureIDs = ["barrel": [], "barrelProperties": [], "openingProperties": []]
        error = nil
        if hadDraft { onParentDraftChange(false) }
        await reload(expectedRevision: nil)
    }

    private func reload(expectedRevision: String?) async {
        guard let model = currentModel, let asset = currentAsset else { return }
        await fetch(model: model, expectedRevision: expectedRevision, asset: asset, draftState: nil)
    }

    private func fetch(model: GeometryCulvertModelRequest, expectedRevision: String?, asset: ProjectAsset,
                       draftState: String?) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        error = nil
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let loaded = try await provider.load(model, expectedRevision: expectedRevision,
                draftState: draftState, selectedBarrelIDs: selectedFeatureIDs["barrel", default: []].sorted())
            guard generation == loadGeneration, currentAsset?.id == asset.id,
                  currentModel == model, !Task.isCancelled else { return }
            snapshot = loaded
            expectedSourceRevision = loaded.revision
            if terrainPreview?.dependencyRevision != loaded.dependencyRevision {
                terrainPreviewGeneration += 1
                terrainPreview = nil
                terrainPreviewError = nil
                isLoadingTerrainPreview = false
            }
            didLoad = true
            isProfileContextStale = false
            selectedFeatureIDs["barrel"] = selectedFeatureIDs["barrel", default: []].intersection(Set(loaded.barrels.rows.map(\.id)))
            selectedFeatureIDs["barrelProperties"] = selectedFeatureIDs["barrelProperties", default: []].intersection(Set(loaded.barrelProperties.rows.map(\.id)))
            selectedFeatureIDs["openingProperties"] = selectedFeatureIDs["openingProperties", default: []].intersection(Set(loaded.openingProperties.rows.map(\.id)))
            invalidateStaleMapCommandPreview()
            if smartAddContext != nil, !smartAddContextIsCurrent {
                invalidateSmartAddPreview()
                smartAddError = L10n.text("The geometry or associated terrain changed during Smart Add. Cancel this sketch before continuing.")
            }
        } catch {
            guard generation == loadGeneration, currentAsset?.id == asset.id,
                  currentModel == model, !Task.isCancelled else { return }
            isProfileContextStale = true
            invalidateMapCommandPreview()
            if smartAddContext != nil {
                invalidateSmartAddPreview()
                smartAddError = L10n.text("The geometry or associated terrain changed during Smart Add. Cancel this sketch before continuing.")
            }
            self.error = error.localizedDescription
            didLoad = false
        }
    }

    @discardableResult
    private func submit(_ mutation: GeometryCulvertMutation) async -> Bool {
        guard canEdit, !isEditing, let current = snapshot, let model = currentModel,
              let assetID = currentAsset?.id else { return false }
        let generation = loadGeneration
        isEditing = true
        error = nil
        defer { if generation == loadGeneration { isEditing = false } }
        do {
            let updated = try await provider.edit(model, revision: current.revision,
                draftState: current.draftState, mutation: mutation,
                selectedBarrelIDs: selectedFeatureIDs["barrel", default: []].sorted())
            guard generation == loadGeneration, currentAsset?.id == assetID,
                  currentModel == model, !Task.isCancelled else { return false }
            snapshot = updated
            selectedFeatureIDs["barrel"] = selectedFeatureIDs["barrel", default: []]
                .intersection(Set(updated.barrels.rows.map(\.id)))
            selectedFeatureIDs["barrelProperties"] = selectedFeatureIDs["barrelProperties", default: []]
                .intersection(Set(updated.barrelProperties.rows.map(\.id)))
            selectedFeatureIDs["openingProperties"] = selectedFeatureIDs["openingProperties", default: []]
                .intersection(Set(updated.openingProperties.rows.map(\.id)))
            invalidateStaleMapCommandPreview()
            if smartAddContext != nil, !isFinishingSmartAdd, !smartAddContextIsCurrent {
                invalidateSmartAddPreview()
                smartAddError = L10n.text("The geometry or associated terrain changed during Smart Add. Cancel this sketch before continuing.")
            }
            onParentDraftChange(updated.isDirty)
            return true
        } catch {
            guard generation == loadGeneration, currentAsset?.id == assetID,
                  currentModel == model, !Task.isCancelled else { return false }
            if (error as? BackendServiceError)?.code == "sourceChanged" {
                isProfileContextStale = true
                invalidateMapCommandPreview()
            }
            self.error = error.localizedDescription
            return false
        }
    }

    private func parentCaptureIsCurrent(_ capture: GeometryCulvertParentSaveCapture) -> Bool {
        activeParentSaveID == capture.operationID && modelGeneration == capture.generation
            && currentAsset?.id == capture.assetID
    }

    private func releaseParentSave(_ capture: GeometryCulvertParentSaveCapture) {
        guard parentCaptureIsCurrent(capture) else { return }
        activeParentSaveID = nil
        parentSaveInProgress = false
    }

    /// Keeps a local map edit visible to the parent dirty-state guard until it
    /// is either staged through the provider or explicitly cancelled.
    func setSketchActive(_ active: Bool) {
        if !active, isFinishingSmartAdd { return }
        guard hasActiveSketch != active else { return }
        if !active, smartAddContext != nil { clearSmartAddSketchState() }
        hasActiveSketch = active
        onParentDraftChange(isDirty || hasActiveSketch)
        if !active {
            let context = pendingSketchContext
                ?? (isProfileContextStale ? currentAsset.map { (asset: $0, sourceRevision: expectedSourceRevision) } : nil)
            pendingSketchContext = nil
            if let context {
                Task { await ensureLoaded(asset: context.asset, sourceRevision: context.sourceRevision) }
            }
        }
    }
}
