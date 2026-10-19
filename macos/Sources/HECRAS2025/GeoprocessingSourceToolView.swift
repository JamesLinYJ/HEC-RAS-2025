import AppKit
import CryptoKit
import Foundation
import RASWorkspaceCore
import SwiftUI

private enum GeoprocessingSourceInputMode: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case selected = "Selected"
    var id: String { rawValue }
}

private enum GeoprocessingSourceOutputHandler: String, CaseIterable, Identifiable, Sendable {
    case clipboard = "Clipboard"
    case shapefile = "Shapefile"
    case mapLayer = "Map Layer"
    case tiff = "Tiff"
    case csvFile = "CSV File"
    case textFile = "Text File"
    case inPlace = "In Place"
    var id: String { rawValue }
}

private enum GeoprocessingDistanceAlgorithm: String, CaseIterable, Identifiable, Sendable {
    case edt = "EDT"
    case spatialIndex = "SpatialIndex"
    var id: String { rawValue }
    var title: String { self == .edt ? "Euclidean Distance Transform" : "Spatial Index" }
}

private enum GeoprocessingSearchMode: String, CaseIterable, Identifiable, Sendable {
    case perpendicular = "Perpendicular"
    case radial = "Radial"
    var id: String { rawValue }
    var title: String { self == .perpendicular ? "Perpendicular" : "Radial" }
}

private enum GeoprocessingElevationMode: String, CaseIterable, Identifiable, Sendable {
    case highest = "Highest"
    case lowest = "Lowest"
    var id: String { rawValue }
}

private enum GeoprocessingBufferSmoothing: String, CaseIterable, Identifiable, Sendable {
    case standard = "Standard"
    case movingAverage = "MovingAverage"
    var id: String { rawValue }
    var title: String { self == .standard ? "Standard" : "Moving Average" }
}

private struct GeoprocessingSourceLine: Encodable, Equatable, Sendable {
    let featureIdentity: String
    let pathIdentity: String
    let sourceFeatureIndex: Int
    let pathIndex: Int
    let coordinates: [[Double]]
    let zValues: [String]?
    let mValues: [String]?
}

/// One source polygon feature. `coordinates` is its outer ring and `holes`
/// carries the remaining rings in source order; each feature stays one exact
/// geometry identity even when the input is a MultiPolygon or GeometryCollection.
struct GeoprocessingSourcePolygon: Encodable, Equatable, Sendable {
    let featureIdentity: String
    let pathIdentity: String
    let sourceFeatureIndex: Int
    let pathIndex: Int
    let coordinates: [[Double]]
    let zValues: [String]?
    let mValues: [String]?
    let holes: [[[Double]]]
    let holeZValues: [[String]?]?
    let holeMValues: [[String]?]?
}

private struct GeoprocessingSourcePoint: Encodable, Equatable, Sendable {
    let featureIdentity: String
    let pathIdentity: String
    let sourceFeatureIndex: Int
    let pathIndex: Int
    let coordinates: [Double]
}

private struct GeoprocessingSourceRequest: Encodable, Sendable {
    let sourcePath: String
    let sourceRevision: String
    let projectDirectory: String
    let projectProjectionType: String
    let projectProjectionValue: String
    let operation: String
    let inputMode: String
    let inputLines: [GeoprocessingSourceLine]
    let inputPolygons: [GeoprocessingSourcePolygon]
    let inputPoints: [GeoprocessingSourcePoint]
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
    let rasterSource: RasterMapSourceDescriptor?
    let projectXml: String?
    let bufferWidthText: String
    let bufferSmoothingMethod: String
    let bufferMovingAverageWindowText: String
    let bufferMovingAveragePassesText: String
    let bufferPolygonDistanceText: String
    let cellSizeText: String
    let fillValueText: String
    let backgroundValueText: String
    let maxDistanceCellsText: String
    let distanceAlgorithm: String
    let sigmaCellsText: String
    let searchRadiusText: String
    let sampleSpacingText: String
    let searchMode: String
    let elevationMode: String
    let pointsPerRingText: String
    let iterationsText: String
    let outputCellSizeText: String
    let binCountText: String
    let useAdvancedSizing: Bool
    let boundarySpacingText: String
    let interiorGridSpacingText: String
    let roundTo: String
    let connectivity: String
    let noDataOutputMode: String
    let maxSlopePercentText: String
    let simplifyDistanceText: String
    let minimumRingAreaText: String
    let clipExtent: [Double]?
}

private struct GeoprocessingSourceValidationRequest: Encodable, Sendable {
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
    let bufferWidthText: String
    let bufferSmoothingMethod: String
    let bufferMovingAverageWindowText: String
    let bufferMovingAveragePassesText: String
    let bufferPolygonDistanceText: String
    let cellSizeText: String
    let fillValueText: String
    let backgroundValueText: String
    let maxDistanceCellsText: String
    let distanceAlgorithm: String
    let sigmaCellsText: String
    let searchRadiusText: String
    let sampleSpacingText: String
    let searchMode: String
    let elevationMode: String
    let pointsPerRingText: String
    let iterationsText: String
    let outputCellSizeText: String
    let binCountText: String
    let useAdvancedSizing: Bool
    let boundarySpacingText: String
    let interiorGridSpacingText: String
    let roundTo: String
    let connectivity: String
    let noDataOutputMode: String
    let maxSlopePercentText: String
    let simplifyDistanceText: String
    let minimumRingAreaText: String
    let clipExtent: [Double]?
}

private struct GeoprocessingSourceCancelControl: Encodable, Sendable {
    let type = "cancel"
}

private struct GeoprocessingSourcePolygonOutput: Decodable, Sendable {
    let featureIdentity: String
    let pathIdentity: String
    let sourceFeatureIndex: Int
    let pathIndex: Int
    let coordinates: [[Double]]
    let zValues: [String]?
    let mValues: [String]?
    let holes: [[[Double]]]?
    let holeZValues: [[String]?]?
    let holeMValues: [[String]?]?
}

private struct GeoprocessingSourceIssue: Decodable, Sendable, Identifiable {
    let field: String
    let message: String
    let severity: String
    var id: String { field + "|" + severity + "|" + message }
}

private struct GeoprocessingSourceValidationResponse: Decodable, Sendable {
    let validationIssues: [GeoprocessingSourceIssue]
}

private struct GeoprocessingSourceResponse: Decodable, Sendable {
    let canExecute: Bool
    let operation: String
    let outputTitle: String
    let inputLineCount: Int
    let outputLineCount: Int
    let outputPath: String?
    let clipboardText: String?
    let outputs: [GeoprocessingPolylineOutput]
    let validationIssues: [GeoprocessingSourceIssue]
    let capturedPathIdentities: [String]
    let outputKind: String
    let polygonOutputs: [GeoprocessingSourcePolygonOutput]?
    let inputPolygonCount: Int
    let outputPolygonCount: Int
    let textOutput: String?
    let outputFormat: String?
    let capturedPolygonPathIdentities: [String]?
    let outputRasterWidth: Int?
    let outputRasterHeight: Int?
    let outputRasterExtent: [Double]?
    let inputPointCount: Int
    let capturedPointIdentities: [String]?
}

@MainActor
private final class GeoprocessingSourceRunState: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isCancelling = false
    @Published private(set) var progress: BackendProgressUpdate?
    @Published private(set) var validationIssues: [GeoprocessingSourceIssue] = []
    @Published private(set) var validationStatus: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var completionMessage: String?
    private var operationID: UUID?
    private var validationID = UUID()
    private var task: Task<Void, Never>?
    private var sendCancel: (() -> Void)?

    func begin() -> UUID {
        let id = UUID()
        operationID = id; isRunning = true; isCancelling = false; progress = nil
        validationIssues = []; validationStatus = nil; errorMessage = nil; completionMessage = nil
        validationID = UUID()
        return id
    }
    func current(_ id: UUID) -> Bool { operationID == id }
    func accept(_ value: BackendProgressUpdate, id: UUID) { if operationID == id { progress = value } }
    func accept(_ value: GeoprocessingSourceResponse, id: UUID) {
        guard operationID == id else { return }
        validationID = UUID(); validationIssues = value.validationIssues; validationStatus = nil
    }
    func beginValidation() -> UUID { let id = UUID(); validationID = id; return id }
    func acceptValidation(_ issues: [GeoprocessingSourceIssue], id: UUID) {
        guard validationID == id, !isRunning else { return }
        validationIssues = issues; validationStatus = nil
    }
    func failValidation(id: UUID) {
        guard validationID == id, !isRunning else { return }
        validationStatus = "Parameter validation could not be refreshed."
    }
    func clearValidation() { validationID = UUID(); validationIssues = []; validationStatus = nil }
    func install(_ task: Task<Void, Never>, id: UUID) {
        guard operationID == id else { task.cancel(); return }
        self.task = task
    }
    func installCancellation(_ handler: @escaping () -> Void, id: UUID) {
        guard operationID == id else { return }
        sendCancel = handler
    }
    func cancel() {
        guard isRunning, !isCancelling else { return }
        isCancelling = true
        sendCancel?()
    }
    func fail(_ message: String, id: UUID) { if operationID == id { errorMessage = message } }
    func complete(_ message: String, id: UUID) { if operationID == id { completionMessage = message } }
    func finish(id: UUID) {
        guard operationID == id else { return }
        isRunning = false; isCancelling = false; operationID = nil; task = nil; sendCancel = nil
    }
}

@MainActor
struct GeoprocessingSourceToolView: View {
    @ObservedObject var store: WorkspaceStore
    let mapID: UUID
    let projectSessionID: UUID
    @Binding var operation: GeoprocessingPolylineOperation
    @Binding var isRunning: Bool
    @ObservedObject private var mapState: MapState
    @StateObject private var runState = GeoprocessingSourceRunState()
    @State private var selectedLayerID = ""
    @State private var selectedRasterSourceID = ""
    @State private var inputMode: GeoprocessingSourceInputMode = .all
    @State private var outputHandler: GeoprocessingSourceOutputHandler = .clipboard
    @State private var outputName = ""
    @State private var toleranceText = "0.05"
    @State private var windowText = "5"
    @State private var passesText = "1"
    @State private var maxSegmentLengthText = "10"
    @State private var bufferWidthText = "10"
    @State private var bufferSmoothing: GeoprocessingBufferSmoothing = .standard
    @State private var bufferWindowText = "5"
    @State private var bufferPassesText = "1"
    @State private var bufferPolygonDistanceText = "10"
    @State private var cellSizeText = "10"
    @State private var fillValueText = "1"
    @State private var backgroundValueText = "0"
    @State private var maxDistanceCellsText = "100"
    @State private var distanceAlgorithm: GeoprocessingDistanceAlgorithm = .edt
    @State private var sigmaCellsText = "10"
    @State private var searchRadiusText = "50"
    @State private var sampleSpacingText = "3"
    @State private var searchMode: GeoprocessingSearchMode = .perpendicular
    @State private var elevationMode: GeoprocessingElevationMode = .highest
    @State private var pointsPerRingText = "16"
    @State private var iterationsText = "1"
    @State private var outputCellSizeText = "0"
    @State private var binCountText = "25"
    @State private var useAdvancedSizing = false
    @State private var boundarySpacingText = "10"
    @State private var interiorGridSpacingText = "20"
    @State private var roundTo = "Tenths"
    @State private var connectivity = "EightCorners"
    @State private var noDataOutputMode = "Patch"
    @State private var maxSlopePercentText = "5"
    @State private var simplifyDistanceText = "0"
    @State private var minimumRingAreaText = "0"
    @State private var clipToCurrentMapExtent = false

    init(store: WorkspaceStore, mapID: UUID, projectSessionID: UUID,
         operation: Binding<GeoprocessingPolylineOperation>, isRunning: Binding<Bool>) {
        self.store = store; self.mapID = mapID; self.projectSessionID = projectSessionID
        self._operation = operation; self._isRunning = isRunning
        self._mapState = ObservedObject(wrappedValue: store.mapState(for: mapID))
        self._selectedLayerID = State(initialValue: store.mapState(for: mapID).selectedLayerID ?? "")
    }

    private var isCurrentProject: Bool { projectSessionID == store.projectSessionID }
    private var isBusy: Bool { runState.isRunning }
    private var usesPolygonInput: Bool {
        switch operation {
        case .bufferPolygon, .densifyPolygons, .polygonToPolyline, .rasterizePolygons, .clipRasterToPolygon,
             .rasterCutStats, .laplacianTerrain: true
        default: false
        }
    }
    private var usesRasterOnlyInput: Bool { operation == .resampleRaster || operation == .roundRaster }
    private var needsPointInputs: Bool { operation == .noDataLaplacianFill || operation == .flatAreaDetector }
    private var usesRasterInput: Bool {
        [.snapToHighGround, .clipRasterToPolygon, .rasterCutStats, .laplacianTerrain,
         .resampleRaster, .roundRaster, .noDataLaplacianFill, .flatAreaDetector].contains(operation)
    }
    private var allowsPolygonBoundaryLines: Bool { operation == .snapToHighGround }
    private var isRasterOutput: Bool {
        [.rasterizePolygons, .distanceToLines, .proximityHeatmap, .clipRasterToPolygon, .laplacianTerrain,
         .resampleRaster, .roundRaster, .noDataLaplacianFill].contains(operation)
    }
    private var isTextOutput: Bool { operation == .rasterCutStats }
    private var isPolylineOutput: Bool {
        [.polygonToPolyline, .snapToHighGround].contains(operation)
    }
    private var needsLineInputs: Bool {
        [.bufferPolyline, .polylineToPolygon, .snapToHighGround, .distanceToLines, .proximityHeatmap].contains(operation)
    }
    private var supportsInPlace: Bool {
        guard operation == .snapToHighGround, !usesPolygonInput,
              let layer = selectedLayer, ["geojson", "json", "shp"].contains(layer.url.pathExtension.lowercased()),
              layer.features.allSatisfy({ $0.kind == .line }),
              mapState.polylineEditor.supportsInPlaceGeoprocessing,
              let scope = mapState.polylineEditor.currentScope else { return false }
        return scope.projectSessionID == projectSessionID && scope.mapID == mapID
            && scope.layerID == layer.id && scope.canonicalPath == SourceFilePaths.canonical(layer.url)
            && mapState.polylineEditor.currentSourceRevision?.caseInsensitiveCompare(layer.sourceRevision ?? "") == .orderedSame
            && !mapState.polylineEditor.isSourceStale && !mapState.polylineEditor.isBusy
            && mapState.polylineEditor.isEditAllowed
    }

    private var layers: [MapVectorLayer] {
        mapState.vectors(store.mapLayers).filter { layer in
            guard layer.sourceRevision != nil,
                  ["geojson", "json", "shp"].contains(layer.url.pathExtension.lowercased()) else { return false }
            let kinds = layer.features.filter { feature in
                if usesPolygonInput { return feature.kind == .polygon }
                if needsPointInputs { return feature.kind == .point }
                return feature.kind == .line || (allowsPolygonBoundaryLines && feature.kind == .polygon)
            }
            return kinds.contains { !$0.paths.isEmpty }
        }
    }
    private var selectedLayer: MapVectorLayer? { layers.first { $0.id == selectedLayerID } }
    private var rasterSources: [RasterMapSourceDescriptor] {
        store.rasterMapSourcesForActiveMap.filter { $0.sourceMapID == mapID }
    }
    private var selectedRasterSource: RasterMapSourceDescriptor? {
        rasterSources.first { $0.id == selectedRasterSourceID }
    }
    private var allLines: [GeoprocessingSourceLine] {
        guard let selectedLayer else { return [] }
        return captureLines(from: selectedLayer, selectedFeatureIdentities: nil)
    }
    private var selectedLines: [GeoprocessingSourceLine] {
        guard mapState.selectedLayerID == selectedLayerID,
              !mapState.selectedFeatureIdentities.isEmpty,
              let selectedLayer else { return [] }
        return captureLines(from: selectedLayer, selectedFeatureIdentities: mapState.selectedFeatureIdentities)
    }
    private var activeLines: [GeoprocessingSourceLine] { inputMode == .all ? allLines : selectedLines }
    private var allPolygons: [GeoprocessingSourcePolygon] {
        guard let selectedLayer else { return [] }
        return capturePolygons(from: selectedLayer, selectedFeatureIdentities: nil)
    }
    private var selectedPolygons: [GeoprocessingSourcePolygon] {
        guard mapState.selectedLayerID == selectedLayerID,
              !mapState.selectedFeatureIdentities.isEmpty,
              let selectedLayer else { return [] }
        return capturePolygons(from: selectedLayer, selectedFeatureIdentities: mapState.selectedFeatureIdentities)
    }
    private var activePolygons: [GeoprocessingSourcePolygon] { inputMode == .all ? allPolygons : selectedPolygons }
    private var allPoints: [GeoprocessingSourcePoint] {
        guard let selectedLayer else { return [] }
        return capturePoints(from: selectedLayer, selectedFeatureIdentities: nil)
    }
    private var selectedPoints: [GeoprocessingSourcePoint] {
        guard mapState.selectedLayerID == selectedLayerID,
              !mapState.selectedFeatureIdentities.isEmpty,
              let selectedLayer else { return [] }
        return capturePoints(from: selectedLayer, selectedFeatureIdentities: mapState.selectedFeatureIdentities)
    }
    private var activePoints: [GeoprocessingSourcePoint] { inputMode == .all ? allPoints : selectedPoints }
    private var activeInputCount: Int {
        if needsLineInputs { return activeLines.count }
        if needsPointInputs { return activePoints.count }
        return usesRasterOnlyInput ? (selectedRasterSource == nil ? 0 : 1) : activePolygons.count
    }
    private var allSourceLines: [GeoprocessingSourceLine] {
        guard let selectedLayer else { return [] }
        return captureLines(from: selectedLayer, selectedFeatureIdentities: nil)
    }
    private var allSourcePolygons: [GeoprocessingSourcePolygon] {
        guard let selectedLayer else { return [] }
        return capturePolygons(from: selectedLayer, selectedFeatureIdentities: nil)
    }
    private var hasStableInputIdentities: Bool {
        if usesRasterOnlyInput { return selectedRasterSource != nil && currentProjectXML != nil }
        guard let selectedLayer else { return false }
        let relevantFeatures = selectedLayer.features.filter { feature in
            if needsLineInputs { return feature.kind == .line || (allowsPolygonBoundaryLines && feature.kind == .polygon) }
            if needsPointInputs { return feature.kind == .point }
            return feature.kind == .polygon
        }
        guard relevantFeatures.allSatisfy(\.hasUniqueStableIdentity) else { return false }
        if needsLineInputs {
            let ids = allSourceLines.map(\.pathIdentity)
            return !ids.isEmpty && Set(ids).count == ids.count
                && allSourceLines.allSatisfy { !$0.featureIdentity.isEmpty && !$0.pathIdentity.isEmpty }
        }
        if needsPointInputs {
            let ids = allPoints.map(\.pathIdentity)
            return !ids.isEmpty && Set(ids).count == ids.count
                && allPoints.allSatisfy { !$0.featureIdentity.isEmpty && !$0.pathIdentity.isEmpty }
        }
        let ids = allSourcePolygons.map(\.pathIdentity)
        return !ids.isEmpty && Set(ids).count == ids.count
            && allSourcePolygons.allSatisfy { !$0.featureIdentity.isEmpty && !$0.pathIdentity.isEmpty }
    }
    private var hasConsistentSourceDimensions: Bool {
        guard let selectedLayer, selectedLayer.url.pathExtension.lowercased() == "shp" else { return true }
        return selectedLayer.features.filter { feature in
            if needsLineInputs { return feature.kind == .line || (allowsPolygonBoundaryLines && feature.kind == .polygon) }
            if needsPointInputs { return feature.kind == .point }
            return feature.kind == .polygon
        }.allSatisfy { feature in
            guard let sourcePaths = feature.sourceCoordinatePaths, sourcePaths.count == feature.paths.count else { return false }
            return zip(sourcePaths, feature.paths).allSatisfy { $0.count == $1.count }
        }
    }
    private var sourceInputTitle: String {
        if needsLineInputs { return "Input Lines" }
        if needsPointInputs { return "Seed Points" }
        return usesRasterOnlyInput ? "Input Raster" : "Input Polygons"
    }
    private var sourceLayerTitle: String {
        allowsPolygonBoundaryLines ? "Line or Polygon Layer"
            : needsPointInputs ? "Seed Point Layer"
            : usesPolygonInput ? "Polygon Layer" : "Line Layer"
    }
    private var outputDefaultName: String { operation.outputTitle + " Output" }
    private var currentProjectXML: String? { store.document?.editorXML(overridingDescription: store.descriptionDraft) }
    private var activeClipExtent: [Double]? {
        guard clipToCurrentMapExtent, let extent = mapState.currentExtent, extent.isFiniteAndOrdered,
              extent.lowerLeft.x < extent.upperRight.x, extent.lowerLeft.y < extent.upperRight.y else { return nil }
        return [extent.lowerLeft.x, extent.lowerLeft.y, extent.upperRight.x, extent.upperRight.y]
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Tool") {
                    Picker("Geoprocessing Tool", selection: $operation) {
                        ForEach(GeoprocessingPolylineOperation.allCases.filter(\.isSourceOperation)) { choice in
                            Text(L10n.text(choice.title)).tag(choice)
                        }
                    }
                }
                inputSection
                operationSection
                outputSection
                if !runState.validationIssues.isEmpty || runState.validationStatus != nil {
                    Section("Validation") {
                        if let message = runState.validationStatus {
                            SharedVisualValidationErrorList(errors: [SharedVisualValidationMessage(
                                id: "validation-refresh", text: message, level: .warn)])
                        }
                        ForEach(runState.validationIssues) { issue in
                            LabeledContent {
                                SharedVisualValidationErrorList(errors: [SharedVisualValidationMessage(
                                    id: issue.id, text: issue.message, level: validationLevel(issue.severity))])
                            } label: { Text(L10n.text(validationFieldTitle(issue.field))) }
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
            .disabled(isBusy)

            if isBusy {
                OperationProgressView(title: "Processing…",
                    message: [runState.progress?.taskName, runState.progress?.message]
                        .compactMap { $0 }.filter { !$0.isEmpty }.map(L10n.text).joined(separator: " · "),
                    fraction: runState.progress?.fraction, cancelling: runState.isCancelling,
                    cancel: { runState.cancel() })
                    .padding(.horizontal, 18).padding(.vertical, 10)
            }
            Divider()
            HStack {
                Button(isBusy ? "Cancel" : "Close", role: isBusy ? nil : .cancel) {
                    if isBusy { runState.cancel() } else { store.activeTool = nil }
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
        .onAppear(perform: synchronizeSelections)
        .onChange(of: operation) { oldValue, newValue in
            if outputName.isEmpty || outputName == oldValue.outputTitle + " Output" { outputName = newValue.outputTitle + " Output" }
            if !handlerOptions.contains(outputHandler) { outputHandler = handlerOptions.first ?? .clipboard }
            synchronizeSelections(); runState.clearValidation()
        }
        .onChange(of: layers.map { "\($0.id)|\($0.sourceRevision ?? "")|\(validFamilyCapture(for: $0)?.revision ?? "")" }.joined(separator: "\n")) { _, _ in
            synchronizeSelections()
        }
        .onChange(of: selectedLayerID) { _, _ in runState.clearValidation() }
        .onChange(of: selectedRasterSourceID) { _, _ in runState.clearValidation() }
        .onChange(of: inputMode) { _, _ in runState.clearValidation() }
        .onChange(of: outputHandler) { _, value in
            if value != .clipboard && value != .inPlace && outputName.isEmpty { outputName = outputDefaultName }
            runState.clearValidation()
        }
        .onChange(of: store.projectSessionID) { _, _ in if runState.isRunning { runState.cancel() } }
        .onDisappear { if runState.isRunning { runState.cancel() } }
        .task(id: validationSignature) { await refreshParameterValidation() }
    }

    @ViewBuilder private var inputSection: some View {
        Section("Input") {
            if !usesRasterOnlyInput {
                if layers.isEmpty {
                    ContentUnavailableView(needsPointInputs ? "No Point Layers" : usesPolygonInput ? "No Polygon Layers" : "No Line Layers",
                        systemImage: needsPointInputs ? "mappin.and.ellipse" : usesPolygonInput ? "polygon" : "point.topleft.down.to.point.bottomright.curvepath",
                        description: Text(needsPointInputs
                            ? "Add or load a GeoJSON or Shapefile point layer in the active map before running this tool."
                            : usesPolygonInput
                                ? "Add or load a GeoJSON or Shapefile polygon layer in the active map before running this tool."
                                : "Add or load a GeoJSON or Shapefile line layer in the active map before running this tool."))
                        .frame(minHeight: 92)
                } else {
                    Picker(sourceLayerTitle, selection: $selectedLayerID) {
                        ForEach(layers) { layer in Text(layer.name).tag(layer.id) }
                    }
                    Picker(sourceInputTitle, selection: $inputMode) {
                        Text(needsLineInputs ? "All Lines" : needsPointInputs ? "All Points" : "All Polygons").tag(GeoprocessingSourceInputMode.all)
                        Text(needsLineInputs ? "Selected Lines" : needsPointInputs ? "Selected Points" : "Selected Polygons").tag(GeoprocessingSourceInputMode.selected)
                    }
                    LabeledContent(inputMode == .all ? "Captured features" : "Selected features",
                        value: String(activeInputCount))
                    if inputMode == .selected && activeInputCount == 0 {
                        Text("Select source features from the chosen layer in the active map first.")
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
                        Label("The selected Shapefile dimensions do not match the loaded geometry paths.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if !hasStableInputIdentities {
                        Label("The selected layer has ambiguous geometry identities and cannot be processed safely.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if usesRasterInput {
                if rasterSources.isEmpty {
                    ContentUnavailableView("No Raster Map Layers", systemImage: "square.3.layers.3d.down.right",
                        description: Text("Add or load a checked single-band raster layer to the active map first."))
                        .frame(minHeight: 75)
                } else {
                    Picker("Elevation or Raster Layer", selection: $selectedRasterSourceID) {
                        ForEach(rasterSources) { source in
                            Text(source.nodeName.isEmpty ? source.sourcePath.components(separatedBy: "/").last ?? source.id : source.nodeName)
                                .tag(source.id)
                        }
                    }
                    if selectedRasterSource?.sourceRevision == nil {
                        Label("The selected raster has no captured source revision; the backend will recheck its current source.",
                              systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var operationSection: some View {
        Section("Parameters") {
            switch operation {
            case .bufferPolyline:
                TextField("Buffer Width", text: $bufferWidthText).textFieldStyle(.roundedBorder)
                Picker("Smoothing", selection: $bufferSmoothing) {
                    ForEach(GeoprocessingBufferSmoothing.allCases) { value in Text(L10n.text(value.title)).tag(value) }
                }
                if bufferSmoothing == .movingAverage {
                    TextField("Moving Average Window", text: $bufferWindowText).textFieldStyle(.roundedBorder)
                    TextField("Moving Average Passes", text: $bufferPassesText).textFieldStyle(.roundedBorder)
                }
            case .polylineToPolygon:
                Text("The captured line paths are closed using the retained source polygon conversion.")
                    .font(.caption).foregroundStyle(.secondary)
            case .bufferPolygon:
                TextField("Buffer Distance", text: $bufferPolygonDistanceText).textFieldStyle(.roundedBorder)
                Text("Positive distances expand outer boundaries and contract holes; negative distances contract outer boundaries.")
                    .font(.caption).foregroundStyle(.secondary)
            case .densifyPolygons:
                TextField("Max Segment Length", text: $maxSegmentLengthText).textFieldStyle(.roundedBorder)
            case .polygonToPolyline:
                Text("Each captured outer boundary and hole is emitted as its own line path.")
                    .font(.caption).foregroundStyle(.secondary)
            case .snapToHighGround:
                TextField("Search Radius", text: $searchRadiusText).textFieldStyle(.roundedBorder)
                TextField("Sample Spacing", text: $sampleSpacingText).textFieldStyle(.roundedBorder)
                Picker("Search Mode", selection: $searchMode) {
                    ForEach(GeoprocessingSearchMode.allCases) { value in Text(L10n.text(value.title)).tag(value) }
                }
                Picker("Elevation Mode", selection: $elevationMode) {
                    ForEach(GeoprocessingElevationMode.allCases) { value in Text(L10n.text(value.rawValue)).tag(value) }
                }
                if searchMode == .radial {
                    TextField("Points Per Ring", text: $pointsPerRingText).textFieldStyle(.roundedBorder)
                }
                TextField("Iterations", text: $iterationsText).textFieldStyle(.roundedBorder)
                Text("Polygon sources are processed as their original boundary paths; holes remain individual boundary paths.")
                    .font(.caption).foregroundStyle(.secondary)
            case .rasterizePolygons:
                TextField("Cell Size", text: $cellSizeText).textFieldStyle(.roundedBorder)
                TextField("Fill Value", text: $fillValueText).textFieldStyle(.roundedBorder)
                TextField("Background Value", text: $backgroundValueText).textFieldStyle(.roundedBorder)
            case .distanceToLines:
                TextField("Cell Size", text: $cellSizeText).textFieldStyle(.roundedBorder)
                TextField("Max Distance Cells", text: $maxDistanceCellsText).textFieldStyle(.roundedBorder)
                Picker("Distance Algorithm", selection: $distanceAlgorithm) {
                    ForEach(GeoprocessingDistanceAlgorithm.allCases) { value in Text(L10n.text(value.title)).tag(value) }
                }
            case .proximityHeatmap:
                TextField("Cell Size", text: $cellSizeText).textFieldStyle(.roundedBorder)
                TextField("Sigma Cells", text: $sigmaCellsText).textFieldStyle(.roundedBorder)
                TextField("Max Distance Cells", text: $maxDistanceCellsText).textFieldStyle(.roundedBorder)
                Picker("Distance Algorithm", selection: $distanceAlgorithm) {
                    ForEach(GeoprocessingDistanceAlgorithm.allCases) { value in Text(L10n.text(value.title)).tag(value) }
                }
            case .clipRasterToPolygon:
                TextField("Output Cell Size", text: $outputCellSizeText).textFieldStyle(.roundedBorder)
                Text("Set to 0 to use the selected raster cell size.").font(.caption).foregroundStyle(.secondary)
            case .rasterCutStats:
                TextField("Histogram Bin Count", text: $binCountText).textFieldStyle(.roundedBorder)
            case .laplacianTerrain:
                Toggle("Use Advanced Sizing", isOn: $useAdvancedSizing)
                if useAdvancedSizing {
                    TextField("Boundary Spacing", text: $boundarySpacingText).textFieldStyle(.roundedBorder)
                    TextField("Interior Grid Spacing", text: $interiorGridSpacingText).textFieldStyle(.roundedBorder)
                    TextField("Output Cell Size", text: $outputCellSizeText).textFieldStyle(.roundedBorder)
                } else {
                    TextField("Cell Size", text: $cellSizeText).textFieldStyle(.roundedBorder)
                }
                Text("A retained terrain interpolation is constrained by the captured polygon perimeter and selected elevation raster.")
                    .font(.caption).foregroundStyle(.secondary)
            case .resampleRaster:
                TextField("Target Cell Size", text: $cellSizeText).textFieldStyle(.roundedBorder)
                Text("The retained raster resampler uses linear interpolation in map units.")
                    .font(.caption).foregroundStyle(.secondary)
            case .roundRaster:
                TextField("Target Cell Size", text: $cellSizeText).textFieldStyle(.roundedBorder)
                Picker("Round To", selection: $roundTo) {
                    Text("None").tag("None")
                    Text("1/10").tag("Tenths")
                    Text("1/100").tag("Hundredths")
                    Text("1/1000").tag("Thousandths")
                    Text("1/16").tag("Sixteenths")
                    Text("1/32").tag("ThirtySeconds")
                    Text("1/64").tag("SixtyFourths")
                    Text("1/128").tag("HundredTwentyEighths")
                    Text("1/1024").tag("ThousandTwentyFourths")
                }
                Text("Values are rounded using the selected retained Geospatial.Rasters.RoundTo precision.")
                    .font(.caption).foregroundStyle(.secondary)
            case .noDataLaplacianFill:
                TextField("Working Cell Size", text: $cellSizeText).textFieldStyle(.roundedBorder)
                TextField("Boundary Spacing", text: $boundarySpacingText).textFieldStyle(.roundedBorder)
                TextField("Interior Grid Spacing", text: $interiorGridSpacingText).textFieldStyle(.roundedBorder)
                Picker("Connectivity", selection: $connectivity) {
                    Text("Four Sides").tag("FourSides")
                    Text("Eight Corners").tag("EightCorners")
                }
                Picker("Output Mode", selection: $noDataOutputMode) {
                    Text("Patch").tag("Patch")
                    Text("Full").tag("Full")
                }
                Text("Seed points must fall on NoData cells; connected regions are solved from their sampled boundary using the retained TIN Laplacian.")
                    .font(.caption).foregroundStyle(.secondary)
            case .flatAreaDetector:
                TextField("Cell Size", text: $cellSizeText).textFieldStyle(.roundedBorder)
                TextField("Max Slope (%)", text: $maxSlopePercentText).textFieldStyle(.roundedBorder)
                Picker("Connectivity", selection: $connectivity) {
                    Text("Four Sides").tag("FourSides")
                    Text("Eight Corners").tag("EightCorners")
                }
                TextField("Simplify Distance", text: $simplifyDistanceText).textFieldStyle(.roundedBorder)
                TextField("Minimum Area", text: $minimumRingAreaText).textFieldStyle(.roundedBorder)
                Toggle("Clip to Current Map Extent", isOn: $clipToCurrentMapExtent)
                if clipToCurrentMapExtent {
                    if let extent = activeClipExtent {
                        LabeledContent("Clip Extent", value: extent.map { String($0) }.joined(separator: ", "))
                    } else {
                        Label("The current map extent is unavailable or invalid.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Text("The retained detector follows terrain cells from the captured seed points and returns actual polygon rings.")
                    .font(.caption).foregroundStyle(.secondary)
            default:
                Text("Choose a supported geoprocessing operation.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var outputSection: some View {
        Section("Output") {
            LabeledContent("Output", value: L10n.text(operation.outputTitle))
            Picker("Handler", selection: $outputHandler) {
                ForEach(handlerOptions) { handler in Text(L10n.text(handler.rawValue)).tag(handler) }
            }
            if outputHandler == .clipboard {
                Text(isTextOutput
                    ? "The evaluated raster statistics will be copied as text."
                    : isRasterOutput
                        ? "This operation produces a raster; choose Tiff or Map Layer output instead."
                        : "The output geometry is copied using the source representation supported by this result.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if outputHandler == .inPlace {
                Text("The captured line result will replace the exact active line-layer draft and can be undone before saving.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("Output Name", text: $outputName).textFieldStyle(.roundedBorder)
                if store.document?.directory == nil {
                    Text("Save the project before writing geoprocessing outputs.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if outputHandler == .mapLayer {
                    Text(isRasterOutput
                        ? "The output TIFF will be connected to the active map as a real raster layer."
                        : "The output Shapefile family will be connected to the active map.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var handlerOptions: [GeoprocessingSourceOutputHandler] {
        if isRasterOutput { return [.tiff, .mapLayer] }
        if isTextOutput { return [.clipboard, .csvFile, .textFile] }
        var handlers: [GeoprocessingSourceOutputHandler] = [.clipboard, .shapefile, .mapLayer]
        if supportsInPlace { handlers.append(.inPlace) }
        return handlers
    }

    private var validationRequest: GeoprocessingSourceValidationRequest {
        GeoprocessingSourceValidationRequest(operation: operation.rawValue,
            cultureName: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
            toleranceText: toleranceText, movingAverageWindowText: windowText,
            movingAveragePassesText: passesText,
            outputHandler: outputHandler == .inPlace ? "Clipboard" : outputHandler.rawValue,
            outputName: outputHandler == .clipboard || outputHandler == .inPlace ? nil : outputName,
            minimumLengthText: "10", maxSegmentLengthText: maxSegmentLengthText,
            mergeToleranceText: "1", mergeMode: "PreferClosest", offsetText: "10",
            offsetSides: "Both", includeEndpoints: false,
            bufferWidthText: bufferWidthText, bufferSmoothingMethod: bufferSmoothing.rawValue,
            bufferMovingAverageWindowText: bufferWindowText, bufferMovingAveragePassesText: bufferPassesText,
            bufferPolygonDistanceText: bufferPolygonDistanceText, cellSizeText: cellSizeText,
            fillValueText: fillValueText, backgroundValueText: backgroundValueText,
            maxDistanceCellsText: maxDistanceCellsText, distanceAlgorithm: distanceAlgorithm.rawValue,
            sigmaCellsText: sigmaCellsText, searchRadiusText: searchRadiusText,
            sampleSpacingText: sampleSpacingText, searchMode: searchMode.rawValue,
            elevationMode: elevationMode.rawValue, pointsPerRingText: pointsPerRingText,
            iterationsText: iterationsText, outputCellSizeText: outputCellSizeText,
            binCountText: binCountText, useAdvancedSizing: useAdvancedSizing,
            boundarySpacingText: boundarySpacingText, interiorGridSpacingText: interiorGridSpacingText,
            roundTo: roundTo, connectivity: connectivity, noDataOutputMode: noDataOutputMode,
            maxSlopePercentText: maxSlopePercentText, simplifyDistanceText: simplifyDistanceText,
            minimumRingAreaText: minimumRingAreaText, clipExtent: activeClipExtent)
    }

    private var validationSignature: String {
        let request = validationRequest
        let data = (try? JSONEncoder().encode(request)) ?? Data()
        return data.base64EncodedString()
    }

    private var canRun: Bool {
        guard operation.isSourceOperation, !isBusy, isCurrentProject,
              !store.isSavingAll, !store.isRunningProjectTool,
              hasStableInputIdentities, activeInputCount > 0 else { return false }
        if !usesRasterOnlyInput {
            guard let selectedLayer, hasValidSHA256(selectedLayer.sourceRevision), hasConsistentSourceDimensions else { return false }
            if inputMode == .selected && mapState.selectedLayerID != selectedLayerID { return false }
            if selectedLayer.url.pathExtension.lowercased() == "shp" {
                guard validFamilyCapture(for: selectedLayer) != nil,
                      selectedLayer.targetProjectionWKT?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return false }
            }
        }
        if usesRasterInput {
            guard selectedRasterSource != nil, currentProjectXML != nil else { return false }
        }
        if operation == .flatAreaDetector, clipToCurrentMapExtent, activeClipExtent == nil { return false }
        if outputHandler != .clipboard && outputHandler != .inPlace && store.document?.directory == nil { return false }
        if outputHandler == .inPlace && !supportsInPlace { return false }
        return handlerOptions.contains(outputHandler)
    }

    private func synchronizeSelections() {
        if !layers.contains(where: { $0.id == selectedLayerID }) {
            if let selected = mapState.selectedLayerID, layers.contains(where: { $0.id == selected }) { selectedLayerID = selected }
            else { selectedLayerID = layers.first?.id ?? "" }
        }
        if !rasterSources.contains(where: { $0.id == selectedRasterSourceID }) {
            selectedRasterSourceID = rasterSources.first?.id ?? ""
        }
        if !handlerOptions.contains(outputHandler) { outputHandler = handlerOptions.first ?? .clipboard }
        if outputName.isEmpty { outputName = outputDefaultName }
    }

    private func captureLines(from layer: MapVectorLayer, selectedFeatureIdentities: Set<String>?) -> [GeoprocessingSourceLine] {
        var result: [GeoprocessingSourceLine] = []
        for feature in layer.features {
            guard feature.kind == .line || (allowsPolygonBoundaryLines && feature.kind == .polygon),
                  feature.hasUniqueStableIdentity,
                  selectedFeatureIdentities.map({ $0.contains(feature.stableIdentity) }) ?? true else { continue }
            for pathIndex in feature.paths.indices {
                let points = feature.paths[pathIndex]
                guard points.count >= 2 else { continue }
                let pathID = feature.pathStableIdentities.indices.contains(pathIndex)
                    ? feature.pathStableIdentities[pathIndex] : "\(feature.stableIdentity):path:\(pathIndex)"
                result.append(GeoprocessingSourceLine(featureIdentity: feature.stableIdentity,
                    pathIdentity: pathID, sourceFeatureIndex: feature.sourceFeatureIndex ?? feature.id,
                    pathIndex: pathIndex, coordinates: points.map { [$0.x, $0.y] },
                    zValues: sourceOrdinates(feature.sourceCoordinatePaths?[pathIndex], dimension: \.z),
                    mValues: sourceOrdinates(feature.sourceCoordinatePaths?[pathIndex], dimension: \.m)))
            }
        }
        return result
    }

    private func capturePoints(from layer: MapVectorLayer, selectedFeatureIdentities: Set<String>?) -> [GeoprocessingSourcePoint] {
        layer.features.compactMap { feature in
            guard feature.kind == .point, feature.hasUniqueStableIdentity,
                  selectedFeatureIdentities.map({ $0.contains(feature.stableIdentity) }) ?? true,
                  let path = feature.paths.first, path.count == 1,
                  let point = path.first, point.x.isFinite, point.y.isFinite else { return nil }
            let pathID = feature.pathStableIdentities.first ?? "\(feature.stableIdentity):point"
            return GeoprocessingSourcePoint(featureIdentity: feature.stableIdentity,
                pathIdentity: pathID, sourceFeatureIndex: feature.sourceFeatureIndex ?? feature.id,
                pathIndex: 0, coordinates: [point.x, point.y])
        }
    }

    private func capturePolygons(from layer: MapVectorLayer, selectedFeatureIdentities: Set<String>?) -> [GeoprocessingSourcePolygon] {
        var result: [GeoprocessingSourcePolygon] = []
        for feature in layer.features where feature.kind == .polygon {
            guard feature.hasUniqueStableIdentity,
                  selectedFeatureIdentities.map({ $0.contains(feature.stableIdentity) }) ?? true,
                  let outer = feature.paths.first, outer.count >= 4,
                  outer.first == outer.last,
                  feature.paths.dropFirst().allSatisfy({ $0.count >= 4 && $0.first == $0.last }) else { continue }
            let sourcePaths = feature.sourceCoordinatePaths
            let outerZ = sourceOrdinates(sourcePaths?.first, dimension: \.z)
            let outerM = sourceOrdinates(sourcePaths?.first, dimension: \.m)
            let holePaths = Array(feature.paths.dropFirst())
            let holeZ = holePaths.indices.map { sourceOrdinates(sourcePaths?.dropFirst().dropFirst($0).first, dimension: \.z) }
            let holeM = holePaths.indices.map { sourceOrdinates(sourcePaths?.dropFirst().dropFirst($0).first, dimension: \.m) }
            result.append(GeoprocessingSourcePolygon(featureIdentity: feature.stableIdentity,
                pathIdentity: feature.stableIdentity + "|polygon", sourceFeatureIndex: feature.sourceFeatureIndex ?? feature.id,
                pathIndex: 0, coordinates: outer.map { [$0.x, $0.y] }, zValues: outerZ, mValues: outerM,
                holes: holePaths.map { $0.map { [$0.x, $0.y] } },
                holeZValues: holeZ.contains(where: { $0 != nil }) ? holeZ : nil,
                holeMValues: holeM.contains(where: { $0 != nil }) ? holeM : nil))
        }
        return result
    }

    private func sourceOrdinates(_ path: [MapSourceCoordinate]?, dimension: KeyPath<MapSourceCoordinate, Double?>) -> [String]? {
        guard let path, path.contains(where: { $0[keyPath: dimension] != nil }) else { return nil }
        return path.map { String($0[keyPath: dimension] ?? .nan) }
    }

    private func validFamilyCapture(for layer: MapVectorLayer) -> MapSourceFamilyCapture? {
        guard layer.url.pathExtension.lowercased() == "shp",
              let capture = store.sourceMapVectorFamilyCaptures[mapID]?[SourceFilePaths.canonical(layer.url)],
              capture.family == "shapefile",
              SourceFilePaths.canonical(URL(fileURLWithPath: capture.sourcePath)) == SourceFilePaths.canonical(layer.url),
              let primary = capture.files.first(where: { $0.role == "source" && $0.required }),
              primary.exists,
              primary.revision?.caseInsensitiveCompare(layer.sourceRevision ?? "") == .orderedSame,
              hasValidSHA256(capture.revision) else { return nil }
        return capture
    }

    private func currentSourceMatches(layerID: String, sourcePath: String, revision: String,
                                      family: MapSourceFamilyCapture?, targetProjectionWKT: String?,
                                      capturedAllLines: [GeoprocessingSourceLine],
                                      capturedAllPolygons: [GeoprocessingSourcePolygon],
                                      capturedAllPoints: [GeoprocessingSourcePoint],
                                      capturedSelection: Set<String>,
                                      capturedOperation: GeoprocessingPolylineOperation,
                                      projectPath: String?) async -> Bool {
        guard isCurrentProject,
              operation == capturedOperation,
              store.lastActiveMapID == mapID,
              store.document?.directory.map({ SourceFilePaths.canonical($0) }) == projectPath,
              selectedLayerID == layerID,
              inputMode != .selected || (mapState.selectedLayerID == layerID && mapState.selectedFeatureIdentities == capturedSelection),
              let current = mapState.vectors(store.mapLayers).first(where: { $0.id == layerID }),
              SourceFilePaths.canonical(current.url) == sourcePath,
              current.sourceRevision?.caseInsensitiveCompare(revision) == .orderedSame,
              current.targetProjectionWKT == targetProjectionWKT else { return false }
        if let family {
            guard validFamilyCapture(for: current) == family,
                  let provider = store.layerTreeProvider as? BackendMapTreeProvider,
                  let latest = try? await provider.captureShapefileFamily(sourcePath: sourcePath), latest == family else { return false }
        } else if current.url.pathExtension.lowercased() == "shp" { return false }
        let lines = captureLines(from: current, selectedFeatureIdentities: nil)
        let points = capturePoints(from: current, selectedFeatureIdentities: nil)
        let polygons: [GeoprocessingSourcePolygon]
        do {
            polygons = try await Task.detached(priority: .utility) {
                try GeoprocessingSourceGeometryCapture.polygons(from: current)
            }.value
        } catch {
            return false
        }
        return lines.count == capturedAllLines.count && zip(lines, capturedAllLines).allSatisfy { lhs, rhs in
            lhs.featureIdentity == rhs.featureIdentity && lhs.pathIdentity == rhs.pathIdentity
                && lhs.sourceFeatureIndex == rhs.sourceFeatureIndex && lhs.pathIndex == rhs.pathIndex
                && lhs.coordinates == rhs.coordinates && lhs.zValues == rhs.zValues && lhs.mValues == rhs.mValues
        } && points == capturedAllPoints && polygons == capturedAllPolygons
    }

    private func run() {
        guard canRun, let provider = store.modelProvider as? BackendModelProvider else { return }
        let capturedOperation = operation
        let rasterOnly = usesRasterOnlyInput
        let layer = rasterOnly ? nil : selectedLayer
        let capturedRaster = usesRasterInput ? selectedRasterSource : nil
        guard rasterOnly ? capturedRaster != nil : (layer?.sourceRevision != nil) else { return }
        let projectDirectoryURL = store.document?.directory
        guard outputHandler == .clipboard || outputHandler == .inPlace || projectDirectoryURL != nil else { return }
        let sourcePath: String
        if let layer { sourcePath = SourceFilePaths.canonical(layer.url) }
        else if let capturedRaster { sourcePath = capturedRaster.sourcePath }
        else { return }
        let revision = layer?.sourceRevision ?? capturedRaster?.sourceRevision ?? ""
        let projectPath = projectDirectoryURL.map(SourceFilePaths.canonical)
        let family = layer.flatMap { validFamilyCapture(for: $0) }
        let capturedSelection = mapState.selectedFeatureIdentities
        let capturedMode = inputMode
        let capturedLines = layer.map {
            needsLineInputs ? captureLines(from: $0, selectedFeatureIdentities:
                capturedMode == .selected ? capturedSelection : nil) : []
        } ?? []
        let capturedPoints = layer.map {
            needsPointInputs ? capturePoints(from: $0, selectedFeatureIdentities:
                capturedMode == .selected ? capturedSelection : nil) : []
        } ?? []
        let capturedPolygons: [GeoprocessingSourcePolygon]
        let capturedAllPolygons: [GeoprocessingSourcePolygon]
        do {
            if let layer {
                capturedAllPolygons = try GeoprocessingSourceGeometryCapture.polygons(from: layer)
                capturedPolygons = usesPolygonInput
                    ? try GeoprocessingSourceGeometryCapture.polygons(from: layer,
                        selectedFeatureIdentities: capturedMode == .selected ? capturedSelection : nil)
                    : []
            } else {
                capturedAllPolygons = []
                capturedPolygons = []
            }
        } catch {
            let id = runState.begin()
            runState.fail(error.localizedDescription, id: id)
            runState.finish(id: id)
            return
        }
        let capturedAllLines = layer.map { captureLines(from: $0, selectedFeatureIdentities: nil) } ?? []
        let capturedAllPoints = layer.map { capturePoints(from: $0, selectedFeatureIdentities: nil) } ?? []
        let capturedHandler = outputHandler
        let capturedName = outputName
        let capturedProject = projectSessionID
        let capturedMap = mapID
        let capturedLayer = layer?.id ?? ""
        let capturedRevision = revision
        let capturedTargetProjection = layer?.targetProjectionWKT
        let capturedProjectXML = currentProjectXML
        let capturedRasterInput = usesRasterInput
        let capturedIsRasterOutput = isRasterOutput
        let capturedIsTextOutput = isTextOutput
        let capturedIsPolylineOutput = isPolylineOutput
        let capturedUsesPolygonInput = usesPolygonInput
        let capturedDraftGeneration = mapState.polylineEditor.draftGeneration
        let backendHandler = capturedHandler == .inPlace ? "Clipboard" : capturedHandler.rawValue
        let request = GeoprocessingSourceRequest(sourcePath: sourcePath, sourceRevision: revision,
            projectDirectory: projectPath ?? "", projectProjectionType: store.document?.projectionType ?? "",
            projectProjectionValue: store.document?.projectionValue ?? "", operation: capturedOperation.rawValue,
            inputMode: capturedMode.rawValue, inputLines: capturedLines,
            inputPolygons: capturedPolygons, inputPoints: capturedPoints,
            cultureName: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
            toleranceText: toleranceText, movingAverageWindowText: windowText, movingAveragePassesText: passesText,
            minimumLengthText: "10", maxSegmentLengthText: maxSegmentLengthText, mergeToleranceText: "1",
            mergeMode: "PreferClosest", offsetText: "10", offsetSides: "Both", includeEndpoints: false,
            outputHandler: backendHandler, outputName: capturedHandler == .clipboard || capturedHandler == .inPlace ? nil : capturedName,
            sourceFamily: family, targetProjectionWKT: capturedTargetProjection,
            rasterSource: capturedRaster, projectXml: capturedProjectXML,
            bufferWidthText: bufferWidthText, bufferSmoothingMethod: bufferSmoothing.rawValue,
            bufferMovingAverageWindowText: bufferWindowText, bufferMovingAveragePassesText: bufferPassesText,
            bufferPolygonDistanceText: bufferPolygonDistanceText, cellSizeText: cellSizeText,
            fillValueText: fillValueText, backgroundValueText: backgroundValueText,
            maxDistanceCellsText: maxDistanceCellsText, distanceAlgorithm: distanceAlgorithm.rawValue,
            sigmaCellsText: sigmaCellsText, searchRadiusText: searchRadiusText,
            sampleSpacingText: sampleSpacingText, searchMode: searchMode.rawValue,
            elevationMode: elevationMode.rawValue, pointsPerRingText: pointsPerRingText,
            iterationsText: iterationsText, outputCellSizeText: outputCellSizeText,
            binCountText: binCountText, useAdvancedSizing: useAdvancedSizing,
            boundarySpacingText: boundarySpacingText, interiorGridSpacingText: interiorGridSpacingText,
            roundTo: roundTo, connectivity: connectivity, noDataOutputMode: noDataOutputMode,
            maxSlopePercentText: maxSlopePercentText, simplifyDistanceText: simplifyDistanceText,
            minimumRingAreaText: minimumRingAreaText, clipExtent: activeClipExtent)

        let operationID = runState.begin()
        isRunning = true
        let duplex: BackendDuplexOperation<GeoprocessingSourceCancelControl, BackendProgressUpdate,
            GeoprocessingSourceResponse>
        do {
            duplex = try provider.client.startDuplex("geoprocessing.execute", parameters: request,
                control: GeoprocessingSourceCancelControl.self, event: BackendProgressUpdate.self,
                as: GeoprocessingSourceResponse.self)
        } catch {
            runState.fail(error.localizedDescription, id: operationID)
            runState.finish(id: operationID)
            isRunning = false
            return
        }
        runState.installCancellation({
            try? duplex.sendControl(GeoprocessingSourceCancelControl(), sequence: 1)
        }, id: operationID)
        let task = Task { @MainActor [runState, self] in
            defer { runState.finish(id: operationID); isRunning = false }
            do {
                for try await update in duplex.events {
                    runState.accept(update, id: operationID)
                }
                let response = try await duplex.value()
                guard runState.current(operationID) else { return }
                runState.accept(response, id: operationID)
                guard response.operation == capturedOperation.rawValue,
                      response.inputLineCount == request.inputLines.count,
                      response.inputPolygonCount == request.inputPolygons.count,
                      response.capturedPathIdentities == request.inputLines.map(\.pathIdentity),
                      response.capturedPolygonPathIdentities == request.inputPolygons.map(\.pathIdentity),
                      response.inputPointCount == request.inputPoints.count,
                      response.capturedPointIdentities == request.inputPoints.map(\.pathIdentity) else {
                    throw BackendServiceError(code: "protocolFailure", message: "The geoprocessing response does not match the captured map geometries.")
                }
                if layer != nil {
                    guard await currentSourceMatches(layerID: capturedLayer, sourcePath: sourcePath,
                        revision: capturedRevision, family: family, targetProjectionWKT: capturedTargetProjection,
                        capturedAllLines: capturedAllLines, capturedAllPolygons: capturedAllPolygons,
                        capturedAllPoints: capturedAllPoints, capturedSelection: capturedSelection,
                        capturedOperation: capturedOperation, projectPath: projectPath) else {
                        throw BackendServiceError(code: "sourceChanged", message: "The map source changed while the operation was running; the output was not applied.")
                    }
                } else {
                    guard store.lastActiveMapID == capturedMap,
                          capturedRaster != nil, rasterSources.contains(where: { $0 == capturedRaster }),
                          store.document?.editorXML(overridingDescription: store.descriptionDraft) == capturedProjectXML else {
                        throw BackendServiceError(code: "sourceChanged", message: "The selected raster or project changed while the operation was running; the output was not applied.")
                    }
                }
                if capturedRasterInput {
                    guard store.lastActiveMapID == capturedMap,
                          capturedRaster != nil,
                          rasterSources.contains(where: { $0 == capturedRaster }),
                          store.document?.editorXML(overridingDescription: store.descriptionDraft) == capturedProjectXML else {
                        throw BackendServiceError(code: "sourceChanged", message: "The selected raster or project changed while the operation was running; the output was not applied.")
                    }
                }
                guard response.canExecute else { return }
                try await apply(response, layer: layer, operation: capturedOperation,
                    isRasterOutput: capturedIsRasterOutput, isTextOutput: capturedIsTextOutput,
                    isPolylineOutput: capturedIsPolylineOutput, usesPolygonInput: capturedUsesPolygonInput,
                    sourcePath: sourcePath, sourceRevision: capturedRevision,
                    capturedLines: capturedLines, capturedPolygons: capturedPolygons,
                    capturedHandler: capturedHandler, capturedProject: capturedProject,
                    capturedMap: capturedMap, capturedLayer: capturedLayer, operationID: operationID,
                    draftGeneration: capturedDraftGeneration)
            } catch {
                if runState.current(operationID) {
                    runState.fail(runState.isCancelling ? "The operation was cancelled." : error.localizedDescription,
                                  id: operationID)
                }
            }
        }
        runState.install(task, id: operationID)
    }

    private func apply(_ response: GeoprocessingSourceResponse, layer: MapVectorLayer?,
                       operation: GeoprocessingPolylineOperation,
                       isRasterOutput: Bool, isTextOutput: Bool, isPolylineOutput: Bool,
                       usesPolygonInput: Bool,
                       sourcePath: String, sourceRevision: String,
                       capturedLines: [GeoprocessingSourceLine], capturedPolygons: [GeoprocessingSourcePolygon],
                       capturedHandler: GeoprocessingSourceOutputHandler, capturedProject: UUID,
                       capturedMap: UUID, capturedLayer: String, operationID: UUID,
                       draftGeneration: String) async throws {
        guard response.operation == operation.rawValue,
              response.outputKind == (isRasterOutput ? "Raster" : isTextOutput ? "Text" : isPolylineOutput ? "Polyline" : "Polygon") else {
            throw BackendServiceError(code: "protocolFailure", message: "The geoprocessing result kind does not match the selected operation.")
        }
        if response.outputKind == "Polyline" {
            guard response.outputLineCount == response.outputs.count,
                  response.outputs.allSatisfy({ output in
                      output.coordinates.count >= 2
                          && output.coordinates.allSatisfy { $0.count == 2 && $0[0].isFinite && $0[1].isFinite }
                          && (output.zValues.map { $0.count == output.coordinates.count } ?? true)
                          && (output.mValues.map { $0.count == output.coordinates.count } ?? true)
                  }) else {
                throw BackendServiceError(code: "protocolFailure", message: "The backend returned invalid line geometry.")
            }
        }
        if response.outputKind == "Polygon" {
            let polygons = response.polygonOutputs ?? []
            guard response.outputPolygonCount == polygons.count,
                  polygons.allSatisfy(isValidPolygonOutput) else {
                throw BackendServiceError(code: "protocolFailure", message: "The backend returned invalid polygon geometry or ring relationships.")
            }
        }
        switch capturedHandler {
        case .clipboard:
            if response.outputKind == "Text" {
                guard let text = response.textOutput, !text.isEmpty,
                      store.system.writeClipboard([.init(representations: ["public.utf8-plain-text": Data(text.utf8)])]) else {
                    throw BackendServiceError(code: "clipboardFailure", message: "The raster statistics could not be copied to the clipboard.")
                }
                runState.complete("Copied raster statistics to the clipboard.", id: operationID)
            } else if response.outputKind == "Polyline" {
                guard let text = response.clipboardText, !text.isEmpty else {
                    throw BackendServiceError(code: "protocolFailure", message: "The backend returned no clipboard output.")
                }
                let payload = GeoprocessingPolylineClipboard(lines: response.outputs.map(GeoprocessingClipboardPolyline.init),
                    coordinateProjectionWKT: layer?.targetProjectionWKT)
                try payload.validate()
                let encoded = try JSONEncoder().encode(payload)
                guard store.system.writeClipboard([.init(representations: [
                    GeoprocessingPolylineClipboard.type: encoded,
                    GeoprocessingPolylineClipboard.textType: Data(text.utf8)
                ])]) else {
                    throw BackendServiceError(code: "clipboardFailure", message: "The processed lines could not be copied to the app clipboard.")
                }
                runState.complete("Copied the processed lines to the app clipboard.", id: operationID)
            } else {
                guard let text = response.clipboardText, !text.isEmpty,
                      store.system.writeClipboard([.init(representations: ["public.utf8-plain-text": Data(text.utf8)])]) else {
                    throw BackendServiceError(code: "clipboardFailure", message: "The processed polygons could not be copied to the clipboard.")
                }
                runState.complete("Copied the polygon output as GeoJSON text.", id: operationID)
            }
        case .shapefile, .tiff, .csvFile, .textFile:
            guard let path = response.outputPath else {
                throw BackendServiceError(code: "protocolFailure", message: "The backend returned no output file path.")
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            runState.complete(capturedHandler == .shapefile ? "The Shapefile output was written to Exports."
                : capturedHandler == .tiff ? "The TIFF output was written to Exports."
                : capturedHandler == .csvFile ? "The CSV output was written to Exports."
                : "The text output was written to Exports.", id: operationID)
        case .mapLayer:
            guard capturedProject == store.projectSessionID, capturedMap == store.lastActiveMapID,
                  let path = response.outputPath else {
                throw BackendServiceError(code: "sourceChanged", message: "The project or map changed before the output could be added.")
            }
            let fileURL = URL(fileURLWithPath: path)
            if response.outputKind == "Raster" {
                let sha = try await sha256File(fileURL)
                guard await store.connectRasterSource(fileURL, for: capturedMap, expectedSourceRevision: sha) else {
                    throw BackendServiceError(code: "outputImportFailed",
                        message: store.errorMessage ?? "The TIFF was written but could not be added as a raster map layer.")
                }
                runState.complete("The processed TIFF was added to the active map.", id: operationID)
            } else {
                guard await store.connectVectorSource(fileURL, for: capturedMap) else {
                    throw BackendServiceError(code: "outputImportFailed",
                        message: store.errorMessage ?? "The Shapefile was written but could not be added to the map.")
                }
                runState.complete("The processed Shapefile was added to the active map.", id: operationID)
            }
        case .inPlace:
            guard response.outputKind == "Polyline", !usesPolygonInput,
                  layer != nil,
                  await mapState.polylineEditor.replaceGeoprocessingLinesInPlace(
                    mapID: capturedMap, layerID: capturedLayer,
                    canonicalSourcePath: sourcePath, sourceRevision: sourceRevision,
                    draftGeneration: draftGeneration,
                    capturedPathIdentities: capturedLines.map(\.pathIdentity), outputs: response.outputs) else {
                throw BackendServiceError(code: "sourceChanged",
                    message: mapState.polylineEditor.errorMessage ?? "The captured line editor draft changed before the result could be applied.")
            }
            runState.complete("The processed lines were applied to the active editing draft.", id: operationID)
        }
    }

    private func isValidPolygonOutput(_ output: GeoprocessingSourcePolygonOutput) -> Bool {
        func validRing(_ ring: [[Double]]) -> Bool {
            ring.count >= 4 && ring.allSatisfy { $0.count == 2 && $0[0].isFinite && $0[1].isFinite }
                && ring.first == ring.last
        }
        let holes = output.holes ?? []
        return validRing(output.coordinates) && holes.allSatisfy(validRing)
            && (output.zValues.map { $0.count == output.coordinates.count } ?? true)
            && (output.mValues.map { $0.count == output.coordinates.count } ?? true)
            && (output.holeZValues.map { values in
                values.count == holes.count && zip(values, holes).allSatisfy { pair in
                    pair.0.map { $0.count == pair.1.count } ?? true
                }
            } ?? true)
            && (output.holeMValues.map { values in
                values.count == holes.count && zip(values, holes).allSatisfy { pair in
                    pair.0.map { $0.count == pair.1.count } ?? true
                }
            } ?? true)
    }

    private var validationFieldTitleLookup: [String: String] {
        ["OutputName": "Output Name", "Tolerance": "Filter Tolerance", "BufferWidth": "Buffer Width",
         "BufferDistance": "Buffer Distance", "MaxSegmentLength": "Max Segment Length",
         "MovingAverageWindow": "Moving Average Window", "MovingAveragePasses": "Moving Average Passes",
         "CellSize": "Cell Size", "FillValue": "Fill Value", "BackgroundValue": "Background Value",
         "MaxDistanceCells": "Max Distance Cells", "SigmaCells": "Sigma Cells",
         "SearchRadius": "Search Radius", "SampleSpacing": "Sample Spacing", "PointsPerRing": "Points Per Ring",
         "Iterations": "Iterations", "OutputCellSize": "Output Cell Size", "BinCount": "Histogram Bin Count",
         "BoundarySpacing": "Boundary Spacing", "InteriorGridSpacing": "Interior Grid Spacing"]
    }
    private func validationFieldTitle(_ field: String) -> String { L10n.text(validationFieldTitleLookup[field] ?? field) }
    private func validationLevel(_ value: String) -> SharedVisualValidationLevel {
        switch value { case "Warn": .warn; case "TypeError": .typeError; case "Error": .error; default: .error }
    }

    private func refreshParameterValidation() async {
        guard !runState.isRunning, let provider = store.modelProvider as? BackendModelProvider else { return }
        let request = validationRequest
        let id = runState.beginValidation()
        do {
            try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation()
            let response = try await provider.client.request("geoprocessing.validate", parameters: request,
                as: GeoprocessingSourceValidationResponse.self)
            try Task.checkCancellation(); runState.acceptValidation(response.validationIssues, id: id)
        } catch is CancellationError { return }
        catch { runState.failValidation(id: id) }
    }

    private func hasValidSHA256(_ value: String?) -> Bool {
        guard let value, value.count == 64 else { return false }
        return value.allSatisfy(\.isHexDigit)
    }

    private func sha256File(_ url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation(); hash.update(data: data)
            }
            return hash.finalize().map { String(format: "%02X", $0) }.joined()
        }.value
    }
}
