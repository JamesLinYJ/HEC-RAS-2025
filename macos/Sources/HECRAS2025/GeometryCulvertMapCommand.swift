import Foundation

enum GeometryCulvertSplitMode: String, CaseIterable, Hashable, Sendable {
    case anywhere
    case atVertex

    var wireValue: String {
        switch self {
        case .anywhere: "Anywhere"
        case .atVertex: "AtVertex"
        }
    }
}

enum GeometryCulvertOffsetSides: String, CaseIterable, Hashable, Sendable {
    case left
    case right
    case both

    var wireValue: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .both: "Both"
        }
    }
}

enum GeometryCulvertMapCommand: Hashable, Sendable {
    case split(barrelID: String, coordinate: GeometryCulvertCoordinate,
               mode: GeometryCulvertSplitMode, mapCellSize: Double)
    case merge(barrelIDs: [String], tolerance: Double)
    case offset(barrelID: String, distance: Double, sides: GeometryCulvertOffsetSides,
                includeEndpoints: Bool, keepOriginal: Bool)

    var operation: String {
        switch self {
        case .split(_, _, _, _): "split"
        case .merge(_, _): "merge"
        case .offset(_, _, _, _, _): "offset"
        }
    }

    var requestedFeatureIDs: [String] {
        switch self {
        case .split(_, _, _, _):
            // Split mirrors the source helper's all-barrel hit test. The clicked
            // stable row is carried separately as TargetFeatureID.
            []
        case let .merge(barrelIDs, _):
            Array(Set(barrelIDs)).sorted()
        case let .offset(barrelID, _, _, _, _):
            [barrelID]
        }
    }

    func previewRequest(model: GeometryCulvertModelRequest, revision: String, draftState: String,
                        previewID: String, availableBarrelCount: Int) -> GeometryCulvertMapCommandPreviewRequest {
        let outputDraftIDs: [String]
        switch self {
        case .split(_, _, _, _):
            // SnapHelpers can split every nearby source line at one junction.
            // Every split line produces two rows, so size the candidate ID list
            // from the complete current layer rather than an arbitrary UI cap.
            outputDraftIDs = (0..<max(2, availableBarrelCount * 2)).map { _ in Self.newDraftID() }
        case .offset(_, _, _, _, _):
            outputDraftIDs = (0..<4).map { _ in Self.newDraftID() }
        case let .merge(barrelIDs, _):
            outputDraftIDs = (0..<max(2, Set(barrelIDs).count)).map { _ in Self.newDraftID() }
        }
        return switch self {
        case let .split(barrelID, coordinate, mode, mapCellSize):
            GeometryCulvertMapCommandPreviewRequest(model: model, revision: revision,
                draftState: draftState, previewID: previewID, operation: operation,
                featureIDs: [], splitPoint: coordinate, splitMode: mode.wireValue,
                mapCellSize: mapCellSize, mergeTolerance: nil, offsetDistance: nil,
                offsetSides: nil, includeEndpoints: false, keepOriginal: false,
                outputDraftIDs: outputDraftIDs, targetFeatureID: barrelID)
        case let .merge(barrelIDs, tolerance):
            GeometryCulvertMapCommandPreviewRequest(model: model, revision: revision,
                draftState: draftState, previewID: previewID, operation: operation,
                featureIDs: Array(Set(barrelIDs)).sorted(), splitPoint: nil, splitMode: nil,
                mapCellSize: nil, mergeTolerance: tolerance, offsetDistance: nil,
                offsetSides: nil, includeEndpoints: false, keepOriginal: false,
                outputDraftIDs: outputDraftIDs, targetFeatureID: nil)
        case let .offset(barrelID, distance, sides, includeEndpoints, keepOriginal):
            GeometryCulvertMapCommandPreviewRequest(model: model, revision: revision,
                draftState: draftState, previewID: previewID, operation: operation,
                featureIDs: [barrelID], splitPoint: nil, splitMode: nil,
                mapCellSize: nil, mergeTolerance: nil, offsetDistance: distance,
                offsetSides: sides.wireValue, includeEndpoints: includeEndpoints,
                keepOriginal: keepOriginal, outputDraftIDs: outputDraftIDs, targetFeatureID: nil)
        }
    }

    func mutation(preview: GeometryCulvertMapCommandPreview) -> GeometryCulvertMutation {
        let outputIDs = preview.outputs.map(\.draftID)
        return switch self {
        case let .split(barrelID, coordinate, mode, mapCellSize):
            GeometryCulvertMutation(operation: "split", featureKind: "barrel",
                featureIDs: preview.capturedFeatureIDs, previewID: preview.previewID,
                targetFeatureID: barrelID, outputDraftIDs: outputIDs,
                splitMode: mode.wireValue, mapCellSize: mapCellSize,
                splitPoint: coordinate)
        case let .merge(_, tolerance):
            GeometryCulvertMutation(operation: "merge", featureKind: "barrel",
                featureIDs: preview.capturedFeatureIDs, previewID: preview.previewID,
                outputDraftIDs: outputIDs, mergeTolerance: tolerance)
        case let .offset(_, distance, sides, includeEndpoints, keepOriginal):
            GeometryCulvertMutation(operation: "offset", featureKind: "barrel",
                featureIDs: preview.capturedFeatureIDs, previewID: preview.previewID,
                outputDraftIDs: outputIDs, offsetDistance: distance,
                offsetSides: sides.wireValue, includeEndpoints: includeEndpoints,
                keepOriginal: keepOriginal)
        }
    }

    private static func newDraftID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

struct GeometryCulvertMapCommandPreview: Hashable, Sendable {
    let previewID: String
    let operation: String
    let geometryIdentity: String
    let revision: String
    let draftState: String
    let dependencyRevision: String
    let capturedFeatureIDs: [String]
    let removedFeatureIDs: [String]
    let retainedFeatureIDs: [String]
    let outputs: [GeometryCulvertMapCommandOutput]
    let hasChange: Bool
    let canApply: Bool
    let warningCode: String?
    let errorCode: String?

    init(response: GeometryCulvertMapCommandPreviewResponse, geometryIdentity: String) {
        previewID = response.previewID
        operation = response.operation
        self.geometryIdentity = geometryIdentity
        revision = response.revision
        draftState = response.draftState
        dependencyRevision = response.dependencyRevision
        capturedFeatureIDs = response.capturedFeatureIDs
        removedFeatureIDs = response.removedFeatureIDs
        retainedFeatureIDs = response.retainedFeatureIDs
        outputs = response.outputs
        hasChange = response.hasChange
        canApply = response.canApply
        warningCode = response.warningCode
        errorCode = response.errorCode
    }
}

struct GeometryCulvertSmartAddPreview: Hashable, Sendable {
    let previewID: String
    let geometryIdentity: String
    let revision: String
    let draftState: String
    let dependencyRevision: String
    let terrainName: String?
    let start: GeometryCulvertCoordinate
    let end: GeometryCulvertCoordinate
    let window: GeometryCulvertSmartAddWindow
    let options: GeometryCulvertSmartAddOptions
    let canAppend: Bool
    let path: [GeometryCulvertCoordinate]
    let errorCode: String?

    init(response: GeometryCulvertSmartAddPreviewResponse, geometryIdentity: String,
         start: GeometryCulvertCoordinate, end: GeometryCulvertCoordinate,
         window: GeometryCulvertSmartAddWindow, options: GeometryCulvertSmartAddOptions) {
        previewID = response.previewID
        self.geometryIdentity = geometryIdentity
        revision = response.revision
        draftState = response.draftState
        dependencyRevision = response.dependencyRevision
        terrainName = response.terrainName
        self.start = start
        self.end = end
        self.window = window
        self.options = options
        canAppend = response.canAppend
        path = response.path
        errorCode = response.errorCode
    }
}
