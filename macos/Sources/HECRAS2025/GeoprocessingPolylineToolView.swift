import AppKit
import Foundation
import RASWorkspaceCore
import SwiftUI

enum GeoprocessingPolylineOperation: String, CaseIterable, Identifiable, Sendable {
    case filter = "Filter"
    // The polygon context menu invokes the same source tools with polygon
    // boundaries projected to the tool's Polyline input. Keep those caller
    // variants visible without inventing separate backend algorithms.
    case filterPolygonBoundaries = "FilterPolygonBoundaries"
    case smooth = "Smooth"
    case smoothPolygonBoundaries = "SmoothPolygonBoundaries"
    case reverse = "Reverse"
    case cullByLength = "CullByLength"
    case densifyPolylines = "DensifyPolylines"
    case mergePolylines = "MergePolylines"
    case lineOffset = "LineOffset"
    case bufferPolyline = "BufferPolyline"
    case polylineToPolygon = "PolylineToPolygon"
    case bufferPolygon = "BufferPolygon"
    case densifyPolygons = "DensifyPolygons"
    case polygonToPolyline = "PolygonToPolyline"
    case snapToHighGround = "SnapToHighGround"
    case rasterizePolygons = "RasterizePolygons"
    case distanceToLines = "DistanceToLines"
    case proximityHeatmap = "ProximityHeatmap"
    case clipRasterToPolygon = "ClipRasterToPolygon"
    case rasterCutStats = "RasterCutStats"
    case laplacianTerrain = "LaplacianTerrain"
    case resampleRaster = "ResampleRaster"
    case roundRaster = "RoundRaster"
    case noDataLaplacianFill = "NoDataLaplacianFill"
    case flatAreaDetector = "FlatAreaDetector"

    var id: String { rawValue }
    var backendOperation: GeoprocessingPolylineOperation {
        switch self {
        case .filterPolygonBoundaries: .filter
        case .smoothPolygonBoundaries: .smooth
        default: self
        }
    }
    var inputGeometryKind: MapFeature.Kind {
        switch self {
        case .filterPolygonBoundaries, .smoothPolygonBoundaries: .polygon
        default: .line
        }
    }
    var inputLayerTitle: String { inputGeometryKind == .polygon ? "Polygon Layer" : "Line Layer" }
    var inputPickerTitle: String { inputGeometryKind == .polygon ? "Input Polygons" : "Input Lines" }
    var allInputTitle: String { inputGeometryKind == .polygon ? "All Polygons" : "All Lines" }
    var selectedInputTitle: String { inputGeometryKind == .polygon ? "Selected Polygons" : "Selected Lines" }
    var inputPathTitle: String { inputGeometryKind == .polygon ? "Polygon boundaries" : "Line paths" }
    var selectedInputPathTitle: String {
        inputGeometryKind == .polygon ? "Selected polygon boundaries" : "Selected line paths"
    }
    var noInputLayersTitle: String { inputGeometryKind == .polygon ? "No Polygon Layers" : "No Line Layers" }
    var noInputLayersDescription: String {
        inputGeometryKind == .polygon
            ? "Add or load a GeoJSON or Shapefile polygon layer in the active map before running this tool."
            : "Add or load a GeoJSON or Shapefile line layer in the active map before running this tool."
    }
    var selectInputPrompt: String {
        inputGeometryKind == .polygon
            ? "Select polygon features from the chosen layer in the map first."
            : "Select line features from the chosen layer in the map first."
    }
    var isSourceOperation: Bool {
        switch self {
        case .bufferPolyline, .polylineToPolygon, .bufferPolygon, .densifyPolygons,
             .polygonToPolyline, .snapToHighGround, .rasterizePolygons, .distanceToLines, .proximityHeatmap,
             .clipRasterToPolygon, .rasterCutStats, .laplacianTerrain,
             .resampleRaster, .roundRaster, .noDataLaplacianFill, .flatAreaDetector:
            true
        default: false
        }
    }
    var title: String {
        switch self {
        case .filter: "Filter"
        case .filterPolygonBoundaries: "Filter Polygon Boundaries"
        case .smooth: "Smooth"
        case .smoothPolygonBoundaries: "Smooth Polygon Boundaries"
        case .reverse: "Reverse"
        case .cullByLength: "Cull by Length"
        case .densifyPolylines: "Densify Lines"
        case .mergePolylines: "Merge Lines"
        case .lineOffset: "Offset Lines"
        case .bufferPolyline: "Buffer Lines"
        case .polylineToPolygon: "Convert to Polygons"
        case .bufferPolygon: "Buffer Polygons"
        case .densifyPolygons: "Densify Polygons"
        case .polygonToPolyline: "Convert to Polylines"
        case .snapToHighGround: "Snap to High Ground"
        case .rasterizePolygons: "Rasterize Polygons"
        case .distanceToLines: "Distance to Lines"
        case .proximityHeatmap: "Proximity Heatmap"
        case .clipRasterToPolygon: "Clip Raster to Polygon"
        case .rasterCutStats: "Raster Cut Stats"
        case .laplacianTerrain: "Fill Surface"
        case .resampleRaster: "Resample Raster"
        case .roundRaster: "Round Raster"
        case .noDataLaplacianFill: "Fill NoData (Laplacian)"
        case .flatAreaDetector: "Flat Area Detector"
        }
    }
    var outputTitle: String {
        switch self {
        case .filter: "Filtered Polylines"
        case .filterPolygonBoundaries: "Filtered Polylines"
        case .smooth: "Smoothed Lines"
        case .smoothPolygonBoundaries: "Smoothed Lines"
        case .reverse: "Reversed Lines"
        case .cullByLength: "Remaining Polylines"
        case .densifyPolylines: "Densified Lines"
        case .mergePolylines: "Merged Lines"
        case .lineOffset: "Offset Lines"
        case .bufferPolyline: "Buffered Polygons"
        case .polylineToPolygon: "Polygons"
        case .bufferPolygon: "Buffered Polygons"
        case .densifyPolygons: "Densified Polygons"
        case .polygonToPolyline: "Polylines"
        case .snapToHighGround: "Snapped Lines"
        case .rasterizePolygons: "Rasterized Polygons"
        case .distanceToLines: "Distance To Lines"
        case .proximityHeatmap: "Proximity Heatmap"
        case .clipRasterToPolygon: "Clipped Raster"
        case .rasterCutStats: "Raster Cut Statistics"
        case .laplacianTerrain: "Interpolated Terrain"
        case .resampleRaster: "Resampled Raster"
        case .roundRaster: "Rounded Raster"
        case .noDataLaplacianFill: "Filled Raster"
        case .flatAreaDetector: "Detected Flat Areas"
        }
    }
}

private enum GeoprocessingPolylineMergeMode: String, CaseIterable, Identifiable, Sendable {
    case rejectBranching = "RejectBranching"
    case preferClosest = "PreferClosest"
    var id: String { rawValue }
    var title: String { self == .rejectBranching ? "Reject Branching" : "Prefer Closest" }
}

private enum GeoprocessingPolylineOffsetSides: String, CaseIterable, Identifiable, Sendable {
    case both = "Both"
    case left = "Left"
    case right = "Right"
    var id: String { rawValue }
    var title: String { rawValue }
}

private enum GeoprocessingPolylineInputMode: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case selected = "Selected"
    var id: String { rawValue }
}

private enum GeoprocessingPolylineOutputHandler: String, CaseIterable, Identifiable, Sendable {
    case clipboard = "Clipboard"
    case shapefile = "Shapefile"
    case mapLayer = "Map Layer"
    case inPlace = "In Place"
    var id: String { rawValue }
}

private struct GeoprocessingPolylineRequest: Encodable, Sendable {
    let sourcePath: String
    let sourceRevision: String
    let projectDirectory: String
    let projectProjectionType: String
    let projectProjectionValue: String
    let operation: String
    let inputMode: String
    let inputLines: [GeoprocessingPolylineRequestLine]
    let cultureName: String
    let toleranceText: String
    let movingAverageWindowText: String
    let movingAveragePassesText: String
    let minimumLengthText: String
    let maxSegmentLengthText: String
    let mergeToleranceText: String
    let mergeMode: String
    let offsetText: String
    let offsetSides: String
    let includeEndpoints: Bool
    let outputHandler: String
    let outputName: String?
    let sourceFamily: MapSourceFamilyCapture?
    let targetProjectionWKT: String?
}

private struct GeoprocessingPolylineValidationRequest: Encodable, Sendable {
    let operation: String
    let cultureName: String
    let toleranceText: String
    let movingAverageWindowText: String
    let movingAveragePassesText: String
    let outputHandler: String
    let outputName: String?
    let minimumLengthText: String
    let maxSegmentLengthText: String
    let mergeToleranceText: String
    let mergeMode: String
    let offsetText: String
    let offsetSides: String
    let includeEndpoints: Bool
}

private struct GeoprocessingPolylineRequestLine: Encodable, Sendable {
    let featureIdentity: String
    let pathIdentity: String
    let sourceFeatureIndex: Int
    let pathIndex: Int
    let coordinates: [[Double]]
    let zValues: [String]?
    let mValues: [String]?
}

private struct GeoprocessingPolylineResponse: Decodable, Sendable {
    let canExecute: Bool
    let operation: String
    let outputTitle: String
    let inputLineCount: Int
    let outputLineCount: Int
    let outputPath: String?
    let clipboardText: String?
    let outputs: [GeoprocessingPolylineOutput]
    let validationIssues: [GeoprocessingPolylineValidationIssue]
    let capturedPathIdentities: [String]
}

private struct GeoprocessingPolylineValidationResponse: Decodable, Sendable {
    let validationIssues: [GeoprocessingPolylineValidationIssue]
}

struct GeoprocessingPolylineOutput: Decodable, Sendable {
    let featureIdentity: String
    let pathIdentity: String
    let sourceFeatureIndex: Int
    let pathIndex: Int
    let coordinates: [[Double]]
    let zValues: [String]?
    let mValues: [String]?
}

private struct GeoprocessingPolylineValidationIssue: Decodable, Sendable, Identifiable {
    let field: String
    let message: String
    let severity: String
    var id: String { field + "|" + severity + "|" + message }
}

@MainActor
private final class GeoprocessingPolylineRunState: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isCancelling = false
    @Published private(set) var progress: BackendProgressUpdate?
    @Published private(set) var validationIssues: [GeoprocessingPolylineValidationIssue] = []
    @Published private(set) var validationStatusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var completionMessage: String?

    private var operationID: UUID?
    private var task: Task<Void, Never>?

    func begin() -> UUID {
        let id = UUID()
        operationID = id
        isRunning = true
        isCancelling = false
        progress = nil
        validationIssues = []
        validationStatusMessage = nil
        validationRequestID = UUID()
        errorMessage = nil
        completionMessage = nil
        return id
    }

    func accept(_ update: BackendProgressUpdate, operationID: UUID) {
        guard self.operationID == operationID, isRunning else { return }
        progress = update
    }

    func accept(_ response: GeoprocessingPolylineResponse, operationID: UUID) {
        guard self.operationID == operationID, isRunning else { return }
        validationRequestID = UUID()
        validationIssues = response.validationIssues
        validationStatusMessage = nil
    }

    private var validationRequestID = UUID()

    func beginValidation() -> UUID {
        let id = UUID()
        validationRequestID = id
        return id
    }

    func acceptValidation(_ issues: [GeoprocessingPolylineValidationIssue], requestID: UUID) {
        guard validationRequestID == requestID, !isRunning else { return }
        validationIssues = issues
        validationStatusMessage = nil
    }

    func failValidation(requestID: UUID) {
        guard validationRequestID == requestID, !isRunning else { return }
        validationStatusMessage = "Parameter validation could not be refreshed."
    }

    func clearValidation() {
        validationRequestID = UUID()
        validationIssues = []
        validationStatusMessage = nil
    }

    func isCurrent(_ id: UUID) -> Bool { operationID == id }

    func install(_ task: Task<Void, Never>, operationID: UUID) {
        guard self.operationID == operationID else { task.cancel(); return }
        self.task = task
    }

    func cancel() {
        guard isRunning, !isCancelling else { return }
        isCancelling = true
        task?.cancel()
    }

    func fail(_ message: String, operationID: UUID) {
        guard self.operationID == operationID else { return }
        errorMessage = message
    }

    func complete(_ message: String, operationID: UUID) {
        guard self.operationID == operationID else { return }
        completionMessage = message
    }

    func finish(operationID: UUID) {
        guard self.operationID == operationID else { return }
        isRunning = false
        isCancelling = false
        task = nil
        self.operationID = nil
    }
}

@MainActor
struct GeoprocessingPolylineToolView: View {
    @ObservedObject var store: WorkspaceStore
    let mapID: UUID
    let projectSessionID: UUID
    @Binding var isRunning: Bool

    @ObservedObject private var mapState: MapState
    @StateObject private var runState = GeoprocessingPolylineRunState()
    @State private var selectedLayerID = ""
    @State private var operation: GeoprocessingPolylineOperation = .filter
    @State private var inputMode: GeoprocessingPolylineInputMode = .all
    @State private var outputHandler: GeoprocessingPolylineOutputHandler = .clipboard
    @State private var toleranceText = "0.05"
    @State private var windowText = "5"
    @State private var passesText = "1"
    @State private var minimumLengthText = "10"
    @State private var maxSegmentLengthText = "10"
    @State private var mergeToleranceText = "1"
    @State private var mergeMode: GeoprocessingPolylineMergeMode = .preferClosest
    @State private var offsetText = "10"
    @State private var offsetSides: GeoprocessingPolylineOffsetSides = .both
    @State private var includeEndpoints = false
    @State private var outputName = "Filtered Polylines Output"

    init(store: WorkspaceStore, mapID: UUID, projectSessionID: UUID, isRunning: Binding<Bool>) {
        self.store = store
        self.mapID = mapID
        self.projectSessionID = projectSessionID
        self._isRunning = isRunning
        self._mapState = ObservedObject(wrappedValue: store.mapState(for: mapID))
        _selectedLayerID = State(initialValue: store.mapState(for: mapID).selectedLayerID ?? "")
    }

    private var layers: [MapVectorLayer] {
        mapState.vectors(store.mapLayers).filter { layer in
            guard layer.sourceRevision != nil,
                  layer.features.contains(where: { $0.kind == operation.inputGeometryKind && !$0.paths.isEmpty }) else { return false }
            switch layer.url.pathExtension.lowercased() {
            case "geojson", "json": return true
            case "shp": return true
            default: return false
            }
        }
    }

    private var selectedLayer: MapVectorLayer? { layers.first { $0.id == selectedLayerID } }
    private var allLines: [GeoprocessingPolylineRequestLine] {
        selectedLayer.map { captureLines(from: $0, selectedFeatureIdentities: nil, operation: operation) } ?? []
    }

    private var selectedLines: [GeoprocessingPolylineRequestLine] {
        guard mapState.selectedLayerID == selectedLayerID,
              !mapState.selectedFeatureIdentities.isEmpty,
              let selectedLayer else { return [] }
        return captureLines(from: selectedLayer, selectedFeatureIdentities: mapState.selectedFeatureIdentities,
                            operation: operation)
    }

    private var activeLines: [GeoprocessingPolylineRequestLine] {
        inputMode == .all ? allLines : selectedLines
    }

    private var hasStableInputIdentities: Bool {
        guard let selectedLayer else {
            return false
        }
        let features = selectedLayer.features.filter { $0.kind == operation.inputGeometryKind }
        guard features.allSatisfy(\.hasUniqueStableIdentity) else { return false }
        let featureIDs = features.map(\.stableIdentity)
        let lines = allLines
        let pathIDs = lines.map(\.pathIdentity)
        return Set(featureIDs).count == featureIDs.count
            && Set(pathIDs).count == pathIDs.count
            && lines.allSatisfy { !$0.featureIdentity.isEmpty && !$0.pathIdentity.isEmpty
                && $0.sourceFeatureIndex >= 0 && $0.pathIndex >= 0 }
    }

    private var hasConsistentSourceDimensions: Bool {
        guard let selectedLayer, selectedLayer.url.pathExtension.lowercased() == "shp" else { return true }
        return selectedLayer.features.filter { $0.kind == operation.inputGeometryKind }.allSatisfy { feature in
            guard let sourcePaths = feature.sourceCoordinatePaths, sourcePaths.count == feature.paths.count else { return false }
            return zip(sourcePaths, feature.paths).allSatisfy { source, projected in source.count == projected.count }
        }
    }

    private var isCurrentProject: Bool { projectSessionID == store.projectSessionID }
    private var isBusy: Bool { runState.isRunning }
    private var defaultOutputName: String { operation.outputTitle + " Output" }
    private var backendOutputHandler: String {
        outputHandler == .inPlace ? GeoprocessingPolylineOutputHandler.clipboard.rawValue : outputHandler.rawValue
    }
    private var supportsInPlace: Bool {
        guard let selectedLayer,
              ["geojson", "json", "shp"].contains(selectedLayer.url.pathExtension.lowercased()),
              [.filter, .smooth, .reverse, .cullByLength, .densifyPolylines, .mergePolylines].contains(operation),
              mapState.polylineEditor.supportsInPlaceGeoprocessing,
              let scope = mapState.polylineEditor.currentScope else { return false }
        return scope.projectSessionID == projectSessionID && scope.mapID == mapID
            && scope.layerID == selectedLayer.id
            && scope.canonicalPath == SourceFilePaths.canonical(selectedLayer.url)
            && mapState.polylineEditor.currentSourceRevision?.caseInsensitiveCompare(selectedLayer.sourceRevision ?? "") == .orderedSame
            && !mapState.polylineEditor.isSourceStale && !mapState.polylineEditor.isBusy
            && mapState.polylineEditor.isEditAllowed
    }

    var body: some View {
        if operation.isSourceOperation {
            GeoprocessingSourceToolView(store: store, mapID: mapID,
                projectSessionID: projectSessionID, operation: $operation, isRunning: $isRunning)
        } else {
        VStack(spacing: 0) {
            Form {
                Section("Input") {
                    if layers.isEmpty {
                        ContentUnavailableView {
                            Label(L10n.text(operation.noInputLayersTitle),
                                  systemImage: operation.inputGeometryKind == .polygon ? "pentagon" : "point.topleft.down.to.point.bottomright.curvepath")
                        } description: {
                            Text(L10n.text(operation.noInputLayersDescription))
                        }
                            .frame(minHeight: 92)
                    } else {
                        Picker(selection: $selectedLayerID) {
                            ForEach(layers) { layer in Text(layer.name).tag(layer.id) }
                        } label: {
                            Text(L10n.text(operation.inputLayerTitle))
                        }
                        Picker(selection: $inputMode) {
                            Text(L10n.text(operation.allInputTitle)).tag(GeoprocessingPolylineInputMode.all)
                            Text(L10n.text(operation.selectedInputTitle)).tag(GeoprocessingPolylineInputMode.selected)
                        } label: {
                            Text(L10n.text(operation.inputPickerTitle))
                        }
                        HStack {
                            Text(L10n.text(inputMode == .all ? operation.inputPathTitle : operation.selectedInputPathTitle))
                            Spacer()
                            Text("\(activeLines.count)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        if inputMode == .selected && selectedLines.isEmpty {
                            Text(L10n.text(operation.selectInputPrompt))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !hasValidSHA256(selectedLayer?.sourceRevision) {
                            Label("The selected layer has no verified source revision.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if let selectedLayer, selectedLayer.url.pathExtension.lowercased() == "shp",
                           validFamilyCapture(for: selectedLayer) == nil {
                            Label("The selected Shapefile family has no verified source revision.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if let selectedLayer, selectedLayer.url.pathExtension.lowercased() == "shp",
                           selectedLayer.targetProjectionWKT?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                            Label("The selected Shapefile has no captured target projection.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if !hasConsistentSourceDimensions {
                            Label(L10n.text(operation.inputGeometryKind == .polygon
                                ? "The selected Shapefile dimensions do not match the loaded polygon boundaries."
                                : "The selected Shapefile dimensions do not match the loaded line paths."),
                                systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if !hasStableInputIdentities {
                            Label(L10n.text(operation.inputGeometryKind == .polygon
                                ? "The selected layer has ambiguous polygon identities and cannot be processed safely."
                                : "The selected layer has ambiguous line identities and cannot be processed safely."),
                                systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                Section("Operation") {
                    Picker("Tool", selection: $operation) {
                        ForEach(GeoprocessingPolylineOperation.allCases) { item in
                            Text(L10n.text(item.title)).tag(item)
                        }
                    }
                    if operation.backendOperation == .filter {
                        TextField("Filter Tolerance", text: $toleranceText)
                            .textFieldStyle(.roundedBorder)
                        Text("Maximum perpendicular distance a point can deviate from the simplified line. Smaller values preserve more detail.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if operation.backendOperation == .smooth {
                        LabeledContent("Method", value: "Moving Average")
                        TextField("Moving Average Window", text: $windowText)
                            .textFieldStyle(.roundedBorder)
                        Text("Number of neighboring vertices to average together. Larger values produce smoother results.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Moving Average Passes", text: $passesText)
                            .textFieldStyle(.roundedBorder)
                        Text("How many times to repeat the moving average.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if operation == .cullByLength {
                        TextField("Minimum Length", text: $minimumLengthText).textFieldStyle(.roundedBorder)
                        Text("Polylines shorter than this length will be removed.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if operation == .densifyPolylines {
                        TextField("Max Segment Length", text: $maxSegmentLengthText).textFieldStyle(.roundedBorder)
                        Text("Maximum allowed segment length. Segments longer than this will have vertices added.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if operation == .mergePolylines {
                        TextField("Merge Tolerance", text: $mergeToleranceText).textFieldStyle(.roundedBorder)
                        Text("Maximum distance between endpoints to consider them connected.")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("Merge Mode", selection: $mergeMode) {
                            ForEach(GeoprocessingPolylineMergeMode.allCases) { mode in
                                Text(L10n.text(mode.title)).tag(mode)
                            }
                        }
                        Text("How to handle branching when an endpoint has multiple possible connections.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if operation == .lineOffset {
                        TextField("Offset", text: $offsetText).textFieldStyle(.roundedBorder)
                        Text("The amount to offset the line.").font(.caption).foregroundStyle(.secondary)
                        Picker("Banks", selection: $offsetSides) {
                            ForEach(GeoprocessingPolylineOffsetSides.allCases) { side in
                                Text(L10n.text(side.title)).tag(side)
                            }
                        }
                        Text("Which bank or banks to emit, relative to the direction the input line is drawn in.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Include Endpoints", isOn: $includeEndpoints)
                        Text("Also emit a line across each end, connecting the offsets.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Output") {
                    LabeledContent("Output", value: L10n.text(operation.outputTitle))
                    Picker("Handler", selection: $outputHandler) {
                        Text("Clipboard").tag(GeoprocessingPolylineOutputHandler.clipboard)
                        Text("Shapefile").tag(GeoprocessingPolylineOutputHandler.shapefile)
                        Text("Map Layer").tag(GeoprocessingPolylineOutputHandler.mapLayer)
                        if supportsInPlace {
                            Text("In Place").tag(GeoprocessingPolylineOutputHandler.inPlace)
                        }
                    }
                    if outputHandler == .clipboard {
                        Text("The clipboard receives typed output polylines and their source text representation; Z/M ordinates are retained when the selected source operation provides them.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        if outputHandler == .inPlace {
                            Text("The captured line result will replace the exact active line-layer draft and can be undone before saving.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            TextField("Output Name", text: $outputName)
                                .textFieldStyle(.roundedBorder)
                            if store.document?.directory == nil {
                                Text("Save the project before writing Shapefile outputs.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if outputHandler == .mapLayer {
                                Text("The new Shapefile will be added to the active map after it is written.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !runState.validationIssues.isEmpty || runState.validationStatusMessage != nil {
                    Section("Validation") {
                        if let message = runState.validationStatusMessage {
                            SharedVisualValidationErrorList(errors: [SharedVisualValidationMessage(
                                id: "validation-refresh", text: message, level: .warn)])
                        }
                        ForEach(runState.validationIssues) { issue in
                            LabeledContent {
                                SharedVisualValidationErrorList(errors: [SharedVisualValidationMessage(
                                    id: issue.id, text: issue.message, level: validationLevel(issue.severity))])
                            } label: {
                                Text(L10n.text(validationFieldTitle(issue.field)))
                            }
                        }
                    }
                }
                if let error = runState.errorMessage {
                    Section("Error") { Text(L10n.text(error)).foregroundStyle(.red).textSelection(.enabled) }
                }
                if let message = runState.completionMessage {
                    Section { Label(L10n.text(message), systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }
            }
            .formStyle(.grouped)

            if isBusy {
                OperationProgressView(title: "Processing…",
                    message: [runState.progress?.taskName, runState.progress?.message]
                        .compactMap { $0 }.filter { !$0.isEmpty }.map(L10n.text).joined(separator: " · "),
                    fraction: runState.progress?.fraction,
                    cancelling: runState.isCancelling,
                    cancel: { runState.cancel() })
                    .padding(.horizontal, 18).padding(.vertical, 10)
            }
            Divider()
            HStack {
                Button(isBusy ? "Cancel" : "Close", role: isBusy ? nil : .cancel) {
                    if isBusy { runState.cancel() }
                    else { store.activeTool = nil }
                }
                .disabled(isBusy && runState.isCancelling)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Run", systemImage: "play.fill") { run() }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(!canRun)
            }
            .padding(16)
        }
        .frame(minWidth: 660, idealWidth: 760, minHeight: 600, idealHeight: 700, maxHeight: 1000)
        .onAppear(perform: synchronizeLayerSelection)
        .onChange(of: layerSignature) { _, _ in synchronizeLayerSelection() }
        .onChange(of: operation) { oldValue, newValue in
            if outputName == oldValue.outputTitle + " Output" {
                outputName = newValue.outputTitle + " Output"
            }
            if outputHandler == .inPlace && !supportsInPlace {
                outputHandler = .clipboard
            }
            runState.clearValidation()
        }
        .onChange(of: selectedLayerID) { _, _ in runState.clearValidation() }
        .onChange(of: inputMode) { _, _ in runState.clearValidation() }
        .onChange(of: toleranceText) { _, _ in runState.clearValidation() }
        .onChange(of: windowText) { _, _ in runState.clearValidation() }
        .onChange(of: passesText) { _, _ in runState.clearValidation() }
        .onChange(of: minimumLengthText) { _, _ in runState.clearValidation() }
        .onChange(of: maxSegmentLengthText) { _, _ in runState.clearValidation() }
        .onChange(of: mergeToleranceText) { _, _ in runState.clearValidation() }
        .onChange(of: mergeMode) { _, _ in runState.clearValidation() }
        .onChange(of: offsetText) { _, _ in runState.clearValidation() }
        .onChange(of: offsetSides) { _, _ in runState.clearValidation() }
        .onChange(of: includeEndpoints) { _, _ in runState.clearValidation() }
        .onChange(of: outputName) { _, _ in runState.clearValidation() }
        .onChange(of: outputHandler) { _, value in
            if value != .clipboard && outputName.isEmpty { outputName = defaultOutputName }
            runState.clearValidation()
        }
        .onChange(of: store.projectSessionID) { _, _ in
            if runState.isRunning { runState.cancel() }
        }
        .onDisappear { if runState.isRunning { runState.cancel() } }
        .task(id: validationSignature) {
            await refreshParameterValidation()
        }
        }
    }

    private var validationRequest: GeoprocessingPolylineValidationRequest {
        GeoprocessingPolylineValidationRequest(
            operation: operation.backendOperation.rawValue,
            cultureName: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
            toleranceText: toleranceText,
            movingAverageWindowText: windowText,
            movingAveragePassesText: passesText,
            outputHandler: backendOutputHandler,
            outputName: outputHandler == .clipboard || outputHandler == .inPlace ? nil : outputName,
            minimumLengthText: minimumLengthText,
            maxSegmentLengthText: maxSegmentLengthText,
            mergeToleranceText: mergeToleranceText,
            mergeMode: mergeMode.rawValue,
            offsetText: offsetText,
            offsetSides: offsetSides.rawValue,
            includeEndpoints: includeEndpoints
        )
    }

    private var validationSignature: String {
        [operation.rawValue, operation.backendOperation.rawValue, Locale.current.identifier, backendOutputHandler,
         outputHandler == .clipboard || outputHandler == .inPlace ? "" : outputName,
         toleranceText, windowText, passesText, minimumLengthText, maxSegmentLengthText,
         mergeToleranceText, mergeMode.rawValue, offsetText, offsetSides.rawValue,
         includeEndpoints ? "1" : "0"].joined(separator: "\u{1f}")
    }

    private func refreshParameterValidation() async {
        guard !runState.isRunning,
              let provider = store.modelProvider as? BackendModelProvider else { return }
        let request = validationRequest
        let requestID = runState.beginValidation()
        do {
            try await Task.sleep(for: .milliseconds(250))
            try Task.checkCancellation()
            let response = try await provider.client.request("geoprocessing.validate", parameters: request,
                as: GeoprocessingPolylineValidationResponse.self)
            try Task.checkCancellation()
            runState.acceptValidation(response.validationIssues, requestID: requestID)
        } catch is CancellationError {
            return
        } catch {
            runState.failValidation(requestID: requestID)
        }
    }

    private var layerSignature: String {
        layers.map { layer in
            let familyRevision = validFamilyCapture(for: layer)?.revision ?? ""
            return "\(layer.id)|\(layer.sourceRevision ?? "")|\(familyRevision)"
        }.joined(separator: "\n")
    }

    private var canRun: Bool {
        guard !isBusy, isCurrentProject, !store.isSavingAll, !store.isRunningProjectTool,
              let selectedLayer, hasStableInputIdentities, hasConsistentSourceDimensions, !activeLines.isEmpty,
              hasValidSHA256(selectedLayer.sourceRevision) else { return false }
        if outputHandler == .inPlace && !supportsInPlace { return false }
        if selectedLayer.url.pathExtension.lowercased() == "shp" && validFamilyCapture(for: selectedLayer) == nil { return false }
        if selectedLayer.url.pathExtension.lowercased() == "shp"
            && selectedLayer.targetProjectionWKT?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { return false }
        if outputHandler != .clipboard && store.document?.directory == nil { return false }
        return true
    }

    private func synchronizeLayerSelection() {
        if layers.contains(where: { $0.id == selectedLayerID }) { return }
        if let selected = mapState.selectedLayerID, layers.contains(where: { $0.id == selected }) {
            selectedLayerID = selected
        } else {
            selectedLayerID = layers.first?.id ?? ""
        }
    }

    private func hasValidSHA256(_ value: String?) -> Bool {
        guard let value, value.count == 64 else { return false }
        return value.allSatisfy(\.isHexDigit)
    }

    private func validationFieldTitle(_ field: String) -> String {
        switch field {
        case "OutputName": L10n.text("Output Name")
        case "Tolerance": L10n.text(operation == .mergePolylines ? "Merge Tolerance" : "Filter Tolerance")
        case "BufferWidth": L10n.text("Offset")
        case "MinLength": L10n.text("Minimum Length")
        case "MaxSegmentLength": L10n.text("Max Segment Length")
        case "Mode": L10n.text("Merge Mode")
        case "Sides": L10n.text("Banks")
        case "MovingAverageWindow": L10n.text("Moving Average Window")
        case "MovingAveragePasses": L10n.text("Moving Average Passes")
        default: L10n.text(field)
        }
    }

    private func validationLevel(_ severity: String) -> SharedVisualValidationLevel {
        switch severity {
        case "Warn": .warn
        case "TypeError": .typeError
        case "Error": .error
        default: .error
        }
    }

    private func validFamilyCapture(for layer: MapVectorLayer) -> MapSourceFamilyCapture? {
        guard layer.url.pathExtension.lowercased() == "shp",
              let capture = store.sourceMapVectorFamilyCaptures[mapID]?[SourceFilePaths.canonical(layer.url)],
              capture.family == "shapefile",
              SourceFilePaths.canonical(URL(fileURLWithPath: capture.sourcePath)) == SourceFilePaths.canonical(layer.url),
              let primary = capture.files.first(where: { $0.role == "source" && $0.required }),
              primary.exists,
              primary.revision?.caseInsensitiveCompare(layer.sourceRevision ?? "") == .orderedSame,
              capture.revision.count == 64, capture.revision.allSatisfy(\.isHexDigit) else { return nil }
        return capture
    }

    private func captureLines(from layer: MapVectorLayer, selectedFeatureIdentities: Set<String>?,
                              operation: GeoprocessingPolylineOperation) -> [GeoprocessingPolylineRequestLine] {
        var lines: [GeoprocessingPolylineRequestLine] = []
        for feature in layer.features where feature.kind == operation.inputGeometryKind {
            if let selectedFeatureIdentities, !selectedFeatureIdentities.contains(feature.stableIdentity) { continue }
            guard feature.hasUniqueStableIdentity else { continue }
            for pathIndex in feature.paths.indices {
                let pathIdentity = feature.pathStableIdentities.indices.contains(pathIndex)
                    ? feature.pathStableIdentities[pathIndex] : "\(feature.stableIdentity):path:\(pathIndex)"
                let points = feature.paths[pathIndex]
                guard points.count >= 2 else { continue }
                lines.append(GeoprocessingPolylineRequestLine(
                    featureIdentity: feature.stableIdentity,
                    pathIdentity: pathIdentity,
                    sourceFeatureIndex: feature.sourceFeatureIndex ?? feature.id,
                    pathIndex: pathIndex,
                    coordinates: points.map { [$0.x, $0.y] },
                    zValues: sourceOrdinates(feature.sourceCoordinatePaths?[pathIndex], dimension: \.z),
                    mValues: sourceOrdinates(feature.sourceCoordinatePaths?[pathIndex], dimension: \.m)
                ))
            }
        }
        return lines
    }

    private func sourceOrdinates(_ path: [MapSourceCoordinate]?,
                                 dimension: KeyPath<MapSourceCoordinate, Double?>) -> [String]? {
        guard let path, path.contains(where: { $0[keyPath: dimension] != nil }) else { return nil }
        return path.map { String($0[keyPath: dimension] ?? .nan) }
    }

    private func currentSourceMatches(layerID: String, path: String, revision: String,
                                      projectDirectory: String?, sourceFamily: MapSourceFamilyCapture?,
                                      targetProjectionWKT: String?,
                                      capturedLines: [GeoprocessingPolylineRequestLine],
                                      operation: GeoprocessingPolylineOperation) async -> Bool {
        guard isCurrentProject,
              store.document?.directory.map({ SourceFilePaths.canonical($0) }) == projectDirectory,
              let current = mapState.vectors(store.mapLayers).first(where: { $0.id == layerID }),
              SourceFilePaths.canonical(current.url) == path,
              current.sourceRevision?.caseInsensitiveCompare(revision) == .orderedSame,
              current.targetProjectionWKT == targetProjectionWKT else { return false }
        if let sourceFamily {
            guard validFamilyCapture(for: current) == sourceFamily,
                  let provider = store.layerTreeProvider as? BackendMapTreeProvider,
                  let latestFamily = try? await provider.captureShapefileFamily(sourcePath: path),
                  latestFamily == sourceFamily else { return false }
        } else if current.url.pathExtension.lowercased() == "shp" {
            return false
        }
        let currentLines = captureLines(from: current, selectedFeatureIdentities: nil, operation: operation)
        return currentLines.count == capturedLines.count
            && zip(currentLines, capturedLines).allSatisfy { current, captured in
                current.featureIdentity == captured.featureIdentity
                    && current.pathIdentity == captured.pathIdentity
                    && current.sourceFeatureIndex == captured.sourceFeatureIndex
                    && current.pathIndex == captured.pathIndex
                    && current.coordinates == captured.coordinates
                    && current.zValues == captured.zValues
                    && current.mValues == captured.mValues
            }
    }

    private func run() {
        guard canRun, let layer = selectedLayer, let revision = layer.sourceRevision,
              let provider = store.modelProvider as? BackendModelProvider else { return }
        let projectDirectoryURL = store.document?.directory
        guard outputHandler == .clipboard || projectDirectoryURL != nil else { return }

        let projectPath = projectDirectoryURL.map { SourceFilePaths.canonical($0) }
        let sourcePath = SourceFilePaths.canonical(layer.url)
        let sourceFamily = validFamilyCapture(for: layer)
        if layer.url.pathExtension.lowercased() == "shp" && sourceFamily == nil { return }
        let lines = activeLines
        let selectedMode = inputMode
        let capturedOperation = operation
        let capturedHandler = outputHandler
        let capturedOutputName = outputName
        let capturedMapID = mapID
        let capturedLayerID = layer.id
        let capturedProjectSession = projectSessionID
        let capturedDraftGeneration = mapState.polylineEditor.draftGeneration
        let request = GeoprocessingPolylineRequest(
            sourcePath: sourcePath,
            sourceRevision: revision,
            projectDirectory: projectPath ?? "",
            projectProjectionType: store.document?.projectionType ?? "",
            projectProjectionValue: store.document?.projectionValue ?? "",
            operation: capturedOperation.backendOperation.rawValue,
            inputMode: selectedMode.rawValue,
            inputLines: lines,
            cultureName: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
            toleranceText: toleranceText,
            movingAverageWindowText: windowText,
            movingAveragePassesText: passesText,
            minimumLengthText: minimumLengthText,
            maxSegmentLengthText: maxSegmentLengthText,
            mergeToleranceText: mergeToleranceText,
            mergeMode: mergeMode.rawValue,
            offsetText: offsetText,
            offsetSides: offsetSides.rawValue,
            includeEndpoints: includeEndpoints,
            outputHandler: capturedHandler == .inPlace ? GeoprocessingPolylineOutputHandler.clipboard.rawValue : capturedHandler.rawValue,
            outputName: capturedHandler == .clipboard || capturedHandler == .inPlace ? nil : capturedOutputName,
            sourceFamily: sourceFamily,
            targetProjectionWKT: layer.targetProjectionWKT
        )

        let operationID = runState.begin()
        isRunning = true
        let task = Task { @MainActor [runState] in
            defer {
                runState.finish(operationID: operationID)
                isRunning = false
            }
            do {
                let response = try await provider.client.request("geoprocessing.execute", parameters: request,
                    as: GeoprocessingPolylineResponse.self, progress: { [runState] update in
                        Task { @MainActor [runState] in runState.accept(update, operationID: operationID) }
                    })
                guard !Task.isCancelled, runState.isCurrent(operationID) else { return }
                runState.accept(response, operationID: operationID)
                guard response.operation == capturedOperation.backendOperation.rawValue,
                      response.inputLineCount == lines.count,
                      response.capturedPathIdentities == lines.map(\.pathIdentity),
                      response.outputLineCount == response.outputs.count else {
                    throw BackendServiceError(code: "protocolFailure", message: "The geoprocessing response does not match the captured map lines.")
                }
                guard await currentSourceMatches(layerID: capturedLayerID, path: sourcePath, revision: revision,
                    projectDirectory: projectPath, sourceFamily: sourceFamily,
                    targetProjectionWKT: layer.targetProjectionWKT,
                    capturedLines: captureLines(from: layer, selectedFeatureIdentities: nil,
                                                operation: capturedOperation),
                    operation: capturedOperation) else {
                    throw BackendServiceError(code: "sourceChanged", message: "The map source changed while the operation was running; the output was not applied.")
                }
                guard response.canExecute else { return }
                guard outputMatchesCapture(response.outputs, inputs: lines,
                                           operation: capturedOperation.backendOperation) else {
                    throw BackendServiceError(code: "protocolFailure", message: "The geoprocessing response does not match the captured map lines.")
                }

                switch capturedHandler {
                case .clipboard:
                    guard !response.outputs.isEmpty else {
                        runState.complete("The operation produced no output lines; the clipboard was left unchanged.", operationID: operationID)
                        return
                    }
                    guard let clipboardText = response.clipboardText, !clipboardText.isEmpty else {
                        throw BackendServiceError(code: "protocolFailure", message: "The backend returned no clipboard output.")
                    }
                    let payload = GeoprocessingPolylineClipboard(
                        lines: response.outputs.map { GeoprocessingClipboardPolyline($0) },
                        coordinateProjectionWKT: layer.targetProjectionWKT
                    )
                    try payload.validate()
                    let encoded = try JSONEncoder().encode(payload)
                    let text = Data(clipboardText.utf8)
                    guard store.system.writeClipboard([.init(representations: [
                        GeoprocessingPolylineClipboard.type: encoded,
                        GeoprocessingPolylineClipboard.textType: text
                    ])]) else {
                        throw BackendServiceError(code: "clipboardFailure", message: "The processed lines could not be copied to the clipboard.")
                    }
                    runState.complete("Copied the processed lines to the app clipboard.", operationID: operationID)
                case .shapefile:
                    guard let outputPath = response.outputPath else {
                        throw BackendServiceError(code: "protocolFailure", message: "The backend returned no Shapefile path.")
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: outputPath)])
                    runState.complete("The Shapefile output was written to Exports.", operationID: operationID)
                case .mapLayer:
                    guard capturedProjectSession == store.projectSessionID,
                          capturedMapID == store.lastActiveMapID,
                          let outputPath = response.outputPath else {
                        throw BackendServiceError(code: "sourceChanged", message: "The project or map changed before the output could be added.")
                    }
                    let imported = await store.connectVectorSource(URL(fileURLWithPath: outputPath), for: capturedMapID)
                    guard imported else {
                        throw BackendServiceError(code: "outputImportFailed",
                            message: store.errorMessage ?? "The Shapefile was written but could not be added to the map.")
                    }
                    runState.complete("The processed lines were added to the active map.", operationID: operationID)
                case .inPlace:
                    let editor = mapState.polylineEditor
                    guard await editor.replaceGeoprocessingLinesInPlace(
                            mapID: capturedMapID, layerID: capturedLayerID,
                            canonicalSourcePath: sourcePath, sourceRevision: revision,
                            draftGeneration: capturedDraftGeneration,
                            capturedPathIdentities: lines.map(\.pathIdentity), outputs: response.outputs) else {
                        throw BackendServiceError(code: "sourceChanged",
                            message: editor.errorMessage ?? "The captured line editor draft changed before the result could be applied.")
                    }
                    runState.complete("The processed lines were applied to the active editing draft.", operationID: operationID)
                }
            } catch is CancellationError {
                if runState.isCurrent(operationID) {
                    runState.fail("The operation was cancelled.", operationID: operationID)
                }
            } catch {
                if runState.isCurrent(operationID) {
                    runState.fail(error.localizedDescription, operationID: operationID)
                }
            }
        }
        runState.install(task, operationID: operationID)
    }

    private func outputMatchesCapture(_ outputs: [GeoprocessingPolylineOutput],
                                      inputs: [GeoprocessingPolylineRequestLine],
                                      operation: GeoprocessingPolylineOperation) -> Bool {
        guard outputs.allSatisfy({ output in
            output.coordinates.count >= 2
                && output.coordinates.allSatisfy({ $0.count == 2 && $0[0].isFinite && $0[1].isFinite })
                && (output.zValues == nil || output.zValues?.count == output.coordinates.count)
                && (output.mValues == nil || output.mValues?.count == output.coordinates.count)
                && !output.featureIdentity.isEmpty && !output.pathIdentity.isEmpty
        }), Set(outputs.map(\.pathIdentity)).count == outputs.count,
            Set(outputs.map(\.featureIdentity)).count == outputs.count else { return false }

        switch operation {
        case .filter, .smooth, .reverse, .densifyPolylines:
            return outputs.count == inputs.count && zip(outputs, inputs).allSatisfy { output, input in
                output.featureIdentity == input.featureIdentity
                    && output.pathIdentity == input.pathIdentity
                    && output.sourceFeatureIndex == input.sourceFeatureIndex
                    && output.pathIndex == input.pathIndex
            }
        case .cullByLength:
            let inputByPath = Dictionary(uniqueKeysWithValues: inputs.map { ($0.pathIdentity, $0) })
            return outputs.allSatisfy { output in
                guard let input = inputByPath[output.pathIdentity] else { return false }
                return output.featureIdentity == input.featureIdentity
                    && output.sourceFeatureIndex == input.sourceFeatureIndex
                    && output.pathIndex == input.pathIndex
            }
        case .mergePolylines, .lineOffset:
            return outputs.enumerated().allSatisfy { index, output in
                output.featureIdentity == "geoprocessing-output-feature:\(index)"
                    && output.pathIdentity == "geoprocessing-output-path:\(index)"
                    && output.sourceFeatureIndex == index && output.pathIndex == 0
            }
        default:
            return false
        }
    }
}
