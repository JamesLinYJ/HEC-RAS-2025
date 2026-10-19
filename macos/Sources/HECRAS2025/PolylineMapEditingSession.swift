import AppKit
import Combine
import CryptoKit
import Foundation
import RASWorkspaceCore

struct PolylineMapEditingScope: Equatable, Hashable, Sendable {
    let projectSessionID: UUID
    let mapID: UUID
    let layerID: String
    let canonicalPath: String

    init(projectSessionID: UUID, mapID: UUID, layerID: String, canonicalPath: String) {
        self.projectSessionID = projectSessionID
        self.mapID = mapID
        self.layerID = layerID
        self.canonicalPath = SourceFilePaths.canonical(URL(fileURLWithPath: canonicalPath))
    }
}

enum PolylineMapEditingTool: String, CaseIterable, Identifiable, Hashable {
    case select, drawLine, editVertices, splitLine, mergeLines, attachEndpoint
    var id: String { rawValue }
}

enum PolylineSelectionShape: String, CaseIterable, Identifiable, Hashable {
    case rectangle, freehandPath, lasso
    var id: String { rawValue }
}

enum PolylineLassoMatchMode: String, CaseIterable, Identifiable, Hashable {
    case intersects, contained
    var id: String { rawValue }
}

struct PolylineCanvasModifiers: OptionSet, Sendable {
    let rawValue: UInt8
    static let option = Self(rawValue: 1 << 0)
    static let command = Self(rawValue: 1 << 1)
    static let control = Self(rawValue: 1 << 2)
    static let shift = Self(rawValue: 1 << 3)
    var extendsSelection: Bool { contains(.command) || contains(.control) || contains(.shift) }
    var mayStartTemporaryTool: Bool { intersection([.command, .control, .shift]).isEmpty }
}

private struct PolylineUndoSnapshot {
    let document: GeoJSONPolylineDocument
    let selectedLineID: String?
    let selectedLineIDs: Set<String>
    let selectedVertexIndices: Set<Int>
    let selectedVertexIndex: Int?
    let openedLineID: String?
}

private struct ShapefilePolylineDraftRecord: Equatable, Sendable {
    var lineID: String?
    var sourceFeatureIdentity: String
    var sourcePartOrdinal: Int?
    var attributeSourceFeatureIndex: Int?
    var points: [MapPoint]
    var sourceCoordinates: [MapSourceCoordinate]
    var displayAttributes: [String: String]
    var attributeColumns: [MapSourceAttributeColumn]
    var isNullRecord: Bool
}

private struct ShapefilePolylineDraft {
    let sourceLayer: MapVectorLayer
    var family: MapSourceFamilyCapture
    var records: [ShapefilePolylineDraftRecord]
    var baselineRecords: [ShapefilePolylineDraftRecord]
    let projectionStatus: String
    let hasZ: Bool
    let hasM: Bool
}

private struct ShapefilePolylineUndoSnapshot {
    let records: [ShapefilePolylineDraftRecord]
    let selectedLineID: String?
    let selectedLineIDs: Set<String>
    let selectedVertexIndices: Set<Int>
    let selectedVertexIndex: Int?
    let openedLineID: String?
}

struct PolylineMapCanvasInput: Sendable {
    enum Kind: Sendable { case click, doubleClick }
    let kind: Kind
    let point: MapPoint
    let lineID: String?
    let vertexIndex: Int?
    let segmentAfterIndex: Int?
    var modifiers: PolylineCanvasModifiers = []
    var maximumDistance: Double?
}

struct PolylineEndpointAttachDraft: Equatable, Sendable {
    let lineID: String
    let anchor: MapPoint
    var point: MapPoint
    let maximumDistance: Double
}

@MainActor
protocol PolylineMapEditingProvider {
    func load(scope: PolylineMapEditingScope) async throws -> GeoJSONPolylineDocument
    func revision(scope: PolylineMapEditingScope) async throws -> String
    func save(scope: PolylineMapEditingScope, expectedRevision: String, data: Data) async throws -> String
}

enum PolylineMapEditingError: LocalizedError {
    case sourceChanged
    case invalidScope
    case noDocument
    case unsupportedShapefileDraft

    var errorDescription: String? {
        switch self {
        case .sourceChanged: "The line source changed on disk. Reload it before saving or editing."
        case .invalidScope: "Polyline editing requires a supported local line file layer."
        case .noDocument: "Load a line layer before editing."
        case .unsupportedShapefileDraft: "The Shapefile line layer does not contain a complete, unambiguous editable source snapshot."
        }
    }
}

@MainActor
final class GeoJSONPolylineMapEditingProvider: PolylineMapEditingProvider {
    func load(scope: PolylineMapEditingScope) async throws -> GeoJSONPolylineDocument {
        let url = try fileURL(for: scope)
        return try GeoJSONPolylineDocument(data: Data(contentsOf: url), sourceURL: url)
    }

    func revision(scope: PolylineMapEditingScope) async throws -> String {
        try Self.digest(Data(contentsOf: fileURL(for: scope)))
    }

    func save(scope: PolylineMapEditingScope, expectedRevision: String, data: Data) async throws -> String {
        let url = try fileURL(for: scope)
        var coordinationError: NSError?
        var writeError: Error?
        var newRevision: String?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                let current = try Data(contentsOf: coordinatedURL)
                guard Self.digest(current) == expectedRevision else { throw PolylineMapEditingError.sourceChanged }
                try data.write(to: coordinatedURL, options: .atomic)
                newRevision = Self.digest(data)
            } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
        guard let newRevision else { throw CocoaError(.fileWriteUnknown) }
        return newRevision
    }

    private func fileURL(for scope: PolylineMapEditingScope) throws -> URL {
        let url = URL(fileURLWithPath: SourceFilePaths.canonical(URL(fileURLWithPath: scope.canonicalPath)))
        guard url.isFileURL, ["geojson", "json"].contains(url.pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: url.path) else { throw PolylineMapEditingError.invalidScope }
        return url
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}

@MainActor
final class PolylineMapEditingSession: ObservableObject {
    private static let maximumGeoprocessVertexCount = 10_000
    @Published private(set) var lines: [GeoJSONPolylineLine] = []
    @Published private(set) var previewPoints: [MapPoint] = []
    @Published private(set) var endpointAttachDraft: PolylineEndpointAttachDraft?
    @Published private(set) var selectedLineID: String?
    @Published private(set) var selectedLineIDs: Set<String> = []
    @Published private(set) var selectedVertexIndex: Int?
    @Published private(set) var selectedVertexIndices: Set<Int> = []
    @Published private(set) var openedLineID: String?
    @Published private(set) var tool: PolylineMapEditingTool = .select
    @Published private(set) var selectionShape: PolylineSelectionShape = .rectangle
    @Published private(set) var lassoMatchMode: PolylineLassoMatchMode = .intersects
    @Published private(set) var splitMode: GeoJSONPolylineSplitMode = .anywhere
    @Published private(set) var mergeTolerance = 5.0
    @Published private(set) var isBusy = false
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var isSourceStale = false
    @Published private(set) var currentScope: PolylineMapEditingScope?
    @Published private(set) var currentSourceRevision: String?
    @Published private(set) var errorMessage: String?

    var didChange: (() -> Void)?
    var didSaveShapefileFamily: ((MapSourceFamilyCapture, MapSourceFamilyCapture, PolylineMapEditingScope) -> Bool)?
    var canEdit: (() -> Bool)?
    var canSave: (() -> Bool)?

    private let provider: any PolylineMapEditingProvider
    private let geoprocessProvider: any PolylineGeoprocessProvider
    private let shapefileProvider = PolylineShapefileEditingProvider()
    private var document: GeoJSONPolylineDocument?
    private var shapefileDraft: ShapefilePolylineDraft?
    private var baseline: Data?
    private var undoStack: [PolylineUndoSnapshot] = []
    private var redoStack: [PolylineUndoSnapshot] = []
    private var shapefileUndoStack: [ShapefilePolylineUndoSnapshot] = []
    private var shapefileRedoStack: [ShapefilePolylineUndoSnapshot] = []
    private var generation: UInt64 = 0
    private var draftMutationGeneration: UInt64 = 0
    private var temporaryToolKey: Character?
    private var temporaryToolRestore: PolylineMapEditingTool?

    init(provider: any PolylineMapEditingProvider,
         geoprocessProvider: any PolylineGeoprocessProvider = BackendPolylineGeoprocessProvider()) {
        self.provider = provider
        self.geoprocessProvider = geoprocessProvider
    }

    var canUndo: Bool { !undoStack.isEmpty || !shapefileUndoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty || !shapefileRedoStack.isEmpty }
    var isEditAllowed: Bool { canEdit?() ?? true }
    var isSaveAllowed: Bool { canSave?() ?? true }
    var canCommitDraft: Bool { hasUnsavedChanges && !isBusy && isSaveAllowed && previewPoints.isEmpty && endpointAttachDraft == nil && !isSourceStale }
    var supportsAddingLines: Bool { document?.supportsAddingLines == true }
    var supportsNativePathEditing: Bool { document != nil }
    var supportsInPlaceGeoprocessing: Bool { document != nil || shapefileDraft != nil }
    var canEditSelectedLine: Bool { document != nil && selectedLine?.canEdit == true && !isBusy && !isSourceStale && isEditAllowed }
    var canDeleteSelectedLine: Bool { canEditSelectedLine && supportsAddingLines }
    var canMergeSelectedLines: Bool {
        selectedLineIDs.count >= 2 && !isBusy && !isSourceStale && isEditAllowed &&
        selectedLines.allSatisfy(\.canEdit) && Set(selectedLines.map(\.sourceFeatureIdentity)).count == 1 &&
        selectedLines.allSatisfy { $0.sourceFeatureOrdinal == selectedLines.first?.sourceFeatureOrdinal && $0.geometryPath == "geometry" }
    }
    var selectedLine: GeoJSONPolylineLine? { lines.first { $0.id == selectedLineID } }
    var selectedLines: [GeoJSONPolylineLine] { lines.filter { selectedLineIDs.contains($0.id) } }
    var selectedPoint: MapPoint? {
        guard let line = selectedLine, let index = selectedVertexIndex, line.points.indices.contains(index) else { return nil }
        return line.points[index]
    }
    var selectedLineSupportsXYGeoprocessing: Bool {
        guard selectedLine != nil else { return false }
        return selectedLineGeoprocessingRestriction == nil
    }
    var selectedLineGeoprocessingRestriction: String? {
        guard let line = selectedLine else { return nil }
        guard line.canEdit, let document else { return "This line identity is ambiguous and cannot be edited safely." }
        do {
            let coordinates = try document.xyCoordinates(lineID: line.id)
            guard coordinates.count <= Self.maximumGeoprocessVertexCount else {
                return "Filter and Smooth support at most 10,000 vertices per operation."
            }
            return nil
        } catch { return error.localizedDescription }
    }

    /// Lines intended for the shared map preview/selection overlay. Each source
    /// component remains independent, with the same stable line identity used by hit testing.
    var currentFeatures: [MapFeature] {
        if let shapefileDraft { return Self.mapFeatures(for: shapefileDraft.records) }
        return lines.enumerated().map { index, line in
            MapFeature(id: index, kind: .line, paths: [line.points], attributes: ["name": line.name],
                stableIdentity: line.sourceFeatureIdentity + "|" + line.geometryPath,
                pathStableIdentities: [line.id], hasUniqueStableIdentity: line.canEdit,
                sourceFeatureIndex: line.sourceFeatureOrdinal,
                geometryPath: line.geometryPath + ".coordinates[\(line.componentOrdinal)]")
        }
    }

    /// Full source layer with the current line draft overlaid. Non-line source
    /// features remain visible; the layer revision stays bound to the captured
    /// file SHA while `draftGeneration` identifies the in-memory presentation.
    var currentMapLayer: MapVectorLayer? {
        if let shapefileDraft, let scope = currentScope,
           let sourceRevision = self.currentSourceRevision {
            return Self.makeMapLayer(for: shapefileDraft, scope: scope, sourceRevision: sourceRevision)
        }
        guard let document, let scope = currentScope, let currentSourceRevision else { return nil }
        // A legacy file-layer ID preserves its displayed alias; a persisted
        // visual node ID is never interpreted as a filename. IO still uses
        // only scope.canonicalPath in the provider.
        let sourceURL = scope.layerID.hasPrefix("/")
            ? URL(fileURLWithPath: scope.layerID) : URL(fileURLWithPath: scope.canonicalPath)
        guard let bytes = try? document.encoded(),
              let parsed = try? MapVectorLayer(data: bytes, sourceURL: sourceURL) else { return nil }
        let features = parsed.features.map { feature -> MapFeature in
            guard feature.kind == .line, let sourceFeatureIndex = feature.sourceFeatureIndex,
                  let geometryPath = feature.geometryPath else { return feature }
            let matching = feature.paths.indices.compactMap { componentIndex in
                lines.first {
                    $0.sourceFeatureOrdinal == sourceFeatureIndex &&
                    $0.geometryPath == geometryPath &&
                    $0.componentOrdinal == componentIndex
                }
            }
            guard matching.count == feature.paths.count, !matching.isEmpty else { return feature }
            return MapFeature(id: feature.id, kind: .line, paths: feature.paths, attributes: feature.attributes,
                stableIdentity: feature.stableIdentity,
                pathStableIdentities: matching.map(\.id),
                hasUniqueStableIdentity: feature.hasUniqueStableIdentity && matching.allSatisfy(\.canEdit),
                sourceFeatureIndex: sourceFeatureIndex, geometryPath: geometryPath)
        }
        return MapVectorLayer(url: sourceURL, features: features,
            sourceMapID: scope.mapID, sourceRevision: currentSourceRevision)
    }

    var draftGeneration: String {
        var value = ""
        if let shapefileDraft {
            value += "shapefile|family=\(shapefileDraft.family.revision)|"
            for record in shapefileDraft.records {
                value += "record=\(record.lineID ?? "null")|attr=\(record.attributeSourceFeatureIndex.map { String($0) } ?? "")|"
                value += record.points.map { "\($0.x),\($0.y)" }.joined(separator: ";")
                value += "|z=" + record.sourceCoordinates.map { coordinate in
                    coordinate.z.map { String($0) } ?? ""
                }.joined(separator: ",")
                value += "|m=" + record.sourceCoordinates.map { coordinate in
                    coordinate.m.map { String($0) } ?? ""
                }.joined(separator: ",") + "\n"
            }
        }
        if let document, let bytes = try? document.encoded() { value = String(decoding: bytes, as: UTF8.self) }
        if let scope = currentScope {
            value += "|project=\(scope.projectSessionID.uuidString)|map=\(scope.mapID.uuidString)|layer=\(scope.layerID)"
        }
        value += "|selected=\(selectedLineID ?? "")|vertex=\(selectedVertexIndex.map(String.init) ?? "")"
        value += "|selectedMany=" + selectedLineIDs.sorted().joined(separator: ",")
        value += "|selectedVertices=" + selectedVertexIndices.sorted().map(String.init).joined(separator: ",")
        value += "|preview=" + previewPoints.map { "\($0.x),\($0.y)" }.joined(separator: ";")
        if let endpointAttachDraft {
            value += "|endpointPreview=\(endpointAttachDraft.lineID)|\(endpointAttachDraft.anchor.x),\(endpointAttachDraft.anchor.y)|\(endpointAttachDraft.point.x),\(endpointAttachDraft.point.y)"
        }
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    func ensureLoaded(scope: PolylineMapEditingScope) async -> Bool {
        if currentScope == scope, document != nil || shapefileDraft != nil { return true }
        guard !isBusy else { return false }
        guard !hasUnsavedChanges else {
            errorMessage = "Save or discard the current line edits before switching layers."
            notifyChange(); return false
        }
        guard ["geojson", "json"].contains(URL(fileURLWithPath: scope.canonicalPath).pathExtension.lowercased()) else {
            errorMessage = PolylineMapEditingError.invalidScope.localizedDescription
            notifyChange(); return false
        }
        generation &+= 1
        let operation = generation
        isBusy = true; notifyChange()
        defer { if generation == operation { isBusy = false; notifyChange() } }
        do {
            let loaded = try await provider.load(scope: scope)
            guard generation == operation, !Task.isCancelled else { return false }
            document = loaded; shapefileDraft = nil; currentScope = scope; currentSourceRevision = loaded.sourceRevision
            baseline = try loaded.encoded(); lines = loaded.lines
            selectedLineID = nil; selectedLineIDs = []; clearVertexSelection(); openedLineID = nil; previewPoints = []; endpointAttachDraft = nil
            isSourceStale = false; hasUnsavedChanges = false; undoStack = []; redoStack = []
            shapefileUndoStack = []; shapefileRedoStack = []; errorMessage = nil
            draftMutationGeneration &+= 1
            notifyChange(); return true
        } catch {
            guard generation == operation else { return false }
            errorMessage = error.localizedDescription; notifyChange(); return false
        }
    }

    func ensureLoadedShapefile(scope: PolylineMapEditingScope, layer: MapVectorLayer,
                               family: MapSourceFamilyCapture) async -> Bool {
        if currentScope == scope, let currentDraft = shapefileDraft,
           currentSourceRevision?.caseInsensitiveCompare(layer.sourceRevision ?? "") == .orderedSame {
            guard currentDraft.family == family else {
                isSourceStale = true
                errorMessage = PolylineMapEditingError.sourceChanged.localizedDescription
                notifyChange()
                return false
            }
            if isSourceStale {
                isSourceStale = false
                errorMessage = nil
                notifyChange()
            }
            return true
        }
        guard !isBusy else { return false }
        guard !hasUnsavedChanges else {
            errorMessage = "Save or discard the current line edits before switching layers."
            notifyChange(); return false
        }
        generation &+= 1
        let operation = generation
        isBusy = true; notifyChange()
        defer { if generation == operation { isBusy = false; notifyChange() } }
        do {
            let normalized = try Self.makeShapefileDraft(layer: layer, scope: scope, family: family)
            let latest = try await shapefileProvider.captureFamily(sourcePath: scope.canonicalPath)
            guard generation == operation, !Task.isCancelled, latest == normalized.family,
                  layer.sourceRevision?.caseInsensitiveCompare(Self.sourceRevision(normalized.family) ?? "") == .orderedSame else {
                throw MapSourceLayerError.sourceChanged
            }
            shapefileDraft = normalized
            document = nil; baseline = nil; currentScope = scope
            currentSourceRevision = Self.sourceRevision(normalized.family)
            lines = Self.lines(from: normalized.records, sourceName: layer.name,
                               revision: currentSourceRevision ?? "")
            selectedLineID = nil; selectedLineIDs = []; clearVertexSelection(); openedLineID = nil
            previewPoints = []; endpointAttachDraft = nil; isSourceStale = false
            hasUnsavedChanges = false; undoStack = []; redoStack = []
            shapefileUndoStack = []; shapefileRedoStack = []; errorMessage = nil
            tool = .select; temporaryToolKey = nil; temporaryToolRestore = nil
            draftMutationGeneration &+= 1
            notifyChange(); return true
        } catch {
            guard generation == operation else { return false }
            if error is MapSourceLayerError { isSourceStale = true }
            errorMessage = error.localizedDescription; notifyChange(); return false
        }
    }

    /// Refuses invalidation while a draft exists. The root owns the user-facing
    /// Save/Discard guard and should call this again after an explicit discard.
    @discardableResult
    func invalidate() -> Bool {
        guard !hasUnsavedChanges, !isBusy else { return false }
        generation &+= 1
        currentScope = nil; currentSourceRevision = nil; document = nil; shapefileDraft = nil; baseline = nil
        lines = []; previewPoints = []; endpointAttachDraft = nil; selectedLineID = nil; selectedLineIDs = []; clearVertexSelection(); openedLineID = nil
        tool = .select; temporaryToolKey = nil; temporaryToolRestore = nil
        shapefileUndoStack = []; shapefileRedoStack = []
        isSourceStale = false; errorMessage = nil; draftMutationGeneration &+= 1; notifyChange()
        return true
    }

    func setTool(_ tool: PolylineMapEditingTool) {
        if temporaryToolKey != nil { releaseTemporaryTool() }
        guard shapefileDraft == nil || tool == .select else { return }
        guard !isBusy, (tool == .select || isEditAllowed) else { return }
        guard previewPoints.isEmpty || tool == self.tool else {
            errorMessage = "Finish or cancel the line drawing before changing tools."
            notifyChange(); return
        }
        guard endpointAttachDraft == nil || tool == self.tool else {
            errorMessage = "Apply or cancel the endpoint preview before changing tools."
            notifyChange(); return
        }
        self.tool = tool
        if tool != .editVertices { clearVertexSelection() }
        if tool != .editVertices { openedLineID = nil }
        notifyChange()
    }

    /// S/M are held actions on the focused canvas. They never start from a
    /// text field or from a modified command chord, and key-up restores the
    /// tool that was active before the hold.
    @discardableResult
    func handleTemporaryToolKey(_ key: Character, isDown: Bool, canvasFocused: Bool,
                                modifiers: PolylineCanvasModifiers = []) -> Bool {
        let key = Character(String(key).lowercased())
        guard key == "s" || key == "m" else { return false }
        if !canvasFocused {
            if !isDown { releaseTemporaryTool() }
            return false
        }
        if isDown {
            guard modifiers.mayStartTemporaryTool else { return false }
            if temporaryToolKey == key { return true }
            guard temporaryToolKey == nil, previewPoints.isEmpty, endpointAttachDraft == nil else { return false }
            temporaryToolKey = key
            temporaryToolRestore = tool
            tool = key == "s" ? .splitLine : .mergeLines
            notifyChange()
            return true
        }
        guard temporaryToolKey == key else { return false }
        releaseTemporaryTool()
        return true
    }

    func releaseTemporaryTool() {
        guard temporaryToolKey != nil else { return }
        let restore = temporaryToolRestore ?? .select
        temporaryToolKey = nil; temporaryToolRestore = nil
        tool = restore
        notifyChange()
    }

    func setSelectionShape(_ shape: PolylineSelectionShape) { selectionShape = shape; notifyChange() }
    func setLassoMatchMode(_ mode: PolylineLassoMatchMode) { lassoMatchMode = mode; notifyChange() }
    func setSplitMode(_ mode: GeoJSONPolylineSplitMode) { splitMode = mode; notifyChange() }
    func setMergeTolerance(_ value: Double) {
        guard value.isFinite, value >= 0 else { return }
        mergeTolerance = value; notifyChange()
    }

    func clearError() { errorMessage = nil; notifyChange() }

    /// Bridge the map reader's source component identity to the editor's
    /// persistent component ID without guessing from coordinates or names.
    @discardableResult
    func selectMapComponent(_ identity: String, in layer: MapVectorLayer) -> Bool {
        guard let scope = currentScope, scope.layerID == layer.id,
              layer.sourceMapID == nil || layer.sourceMapID == scope.mapID,
              SourceFilePaths.canonical(layer.url) == scope.canonicalPath,
              layer.sourceRevision == currentSourceRevision else { return false }
        if lines.contains(where: { $0.id == identity }) {
            selectLine(identity); return true
        }
        let matches = layer.features.filter {
            $0.kind == .line && $0.hasUniqueStableIdentity && $0.pathStableIdentities.contains(identity)
        }
        guard matches.count == 1, let feature = matches.first,
              let ordinal = feature.sourceFeatureIndex, let geometryPath = feature.geometryPath,
              let component = feature.pathStableIdentities.firstIndex(of: identity) else { return false }
        let lineMatches = lines.filter {
            $0.sourceFeatureOrdinal == ordinal && $0.geometryPath == geometryPath && $0.componentOrdinal == component
        }
        guard lineMatches.count == 1, let line = lineMatches.first else { return false }
        selectLine(line.id); return true
    }

    func selectLine(_ id: String?) {
        guard id == nil || lines.contains(where: { $0.id == id }) else { return }
        selectedLineID = id; selectedLineIDs = id.map { Set([$0]) } ?? []
        clearVertexSelection(); notifyChange()
    }

    func selectLine(_ id: String?, additive: Bool) {
        guard additive else { selectLine(id); return }
        guard let id, lines.contains(where: { $0.id == id }) else { return }
        if selectedLineIDs.contains(id) { selectedLineIDs.remove(id) }
        else { selectedLineIDs.insert(id) }
        if selectedLineID == id && !selectedLineIDs.contains(id) {
            selectedLineID = lines.first(where: { selectedLineIDs.contains($0.id) })?.id
        } else if selectedLineIDs.contains(id) { selectedLineID = id }
        clearVertexSelection(); notifyChange()
    }

    func selectLines(_ ids: [String], additive: Bool = false) {
        let valid = Set(ids.filter { id in lines.contains(where: { $0.id == id }) })
        if additive { selectedLineIDs.formSymmetricDifference(valid) }
        else { selectedLineIDs = valid }
        if let primary = selectedLineID, selectedLineIDs.contains(primary) {
            // Keep the existing primary when it remains selected.
        } else {
            selectedLineID = lines.first(where: { selectedLineIDs.contains($0.id) })?.id
        }
        clearVertexSelection(); notifyChange()
    }

    func selectRectangle(from first: MapPoint, to second: MapPoint, additive: Bool = false) {
        let minX = min(first.x, second.x), maxX = max(first.x, second.x)
        let minY = min(first.y, second.y), maxY = max(first.y, second.y)
        let rect = [MapPoint(x: minX, y: minY), MapPoint(x: maxX, y: minY),
                    MapPoint(x: maxX, y: maxY), MapPoint(x: minX, y: maxY)]
        let ids = lines.filter { Self.polylineIntersectsPolygon($0.points, polygon: rect) }.map(\.id)
        selectLines(ids, additive: additive)
    }

    func selectByPath(_ path: [MapPoint], additive: Bool = false) {
        guard path.count >= 2 else { return }
        let ids = lines.filter { line in
            line.points.count >= 2 && Self.polylinesIntersect(line.points, path)
        }.map(\.id)
        selectLines(ids, additive: additive)
    }

    func selectByLasso(_ polygon: [MapPoint], additive: Bool = false,
                       matchMode: PolylineLassoMatchMode? = nil) {
        guard polygon.count >= 3 else { return }
        let matchMode = matchMode ?? lassoMatchMode
        let ids = lines.filter { line in
            switch matchMode {
            case .intersects: Self.polylineIntersectsPolygon(line.points, polygon: polygon)
            case .contained: Self.polylineIsContained(line.points, polygon: polygon)
            }
        }.map(\.id)
        selectLines(ids, additive: additive)
    }

    func openLine(_ id: String) {
        guard !isBusy, !isSourceStale, isEditAllowed,
              let line = lines.first(where: { $0.id == id }), line.canEdit else { return }
        selectLine(id); openedLineID = id; tool = .editVertices; notifyChange()
    }

    func closeLine() {
        guard openedLineID != nil else { return }
        openedLineID = nil; clearVertexSelection()
        if tool == .editVertices { tool = .select }
        notifyChange()
    }

    func toggleOpenLine(_ id: String) {
        if openedLineID == id { closeLine() }
        else { openLine(id) }
    }

    func splitNearestLine(near point: MapPoint, maximumDistance: Double, optionToggledMode: Bool = false) async -> Bool {
        let mode: GeoJSONPolylineSplitMode = optionToggledMode
            ? (splitMode == .anywhere ? .atVertex : .anywhere)
            : splitMode
        guard let line = nearestLine(to: point, mode: mode, maximumDistance: maximumDistance) else {
            errorMessage = mode == .atVertex
                ? "Click near an interior vertex to split at a vertex."
                : "Click close to a line segment to split it."
            notifyChange(); return false
        }
        selectLine(line.id)
        let result: [String]? = await mutateResult { try $0.split(lineID: line.id, near: point, mode: mode, maximumDistance: maximumDistance) }
        guard let result, !result.isEmpty else { return false }
        selectedLineIDs = Set(result); selectedLineID = result.first; clearVertexSelection()
        notifyChange(); return true
    }

    func mergeSelectedLines(tolerance: Double? = nil) async -> Bool {
        guard canMergeSelectedLines else {
            errorMessage = "Select connected components of one MultiLineString to merge safely."; notifyChange(); return false
        }
        let ids = selectedLines.map(\.id)
        let result: [String]? = await mutateResult { try $0.merge(lineIDs: ids, tolerance: tolerance ?? mergeTolerance) }
        guard let result, !result.isEmpty else { return false }
        selectedLineIDs = Set(result); selectedLineID = result.first; clearVertexSelection()
        notifyChange(); return true
    }

    func attachEndpoint(lineID: String, at point: MapPoint, near anchor: MapPoint? = nil,
                        maximumDistance: Double) async -> Bool {
        let result: Int? = await mutateResult {
            try $0.attachEndpoint(lineID: lineID, at: point, near: anchor, maximumDistance: maximumDistance)
        }
        if let result { selectLine(lineID); selectedVertexIndices = [result]; selectedVertexIndex = result; notifyChange(); return true }
        return false
    }

    func beginEndpointAttach(lineID: String, anchor: MapPoint, maximumDistance: Double = 0) {
        guard tool == .attachEndpoint, !isBusy, !isSourceStale, isEditAllowed,
              let line = lines.first(where: { $0.id == lineID }), line.canEdit,
              anchor.x.isFinite, anchor.y.isFinite, maximumDistance.isFinite, maximumDistance >= 0 else { return }
        selectLine(lineID)
        endpointAttachDraft = PolylineEndpointAttachDraft(lineID: lineID, anchor: anchor, point: anchor,
            maximumDistance: maximumDistance)
        draftMutationGeneration &+= 1; updateDirtyState(); notifyChange()
    }

    func updateEndpointAttach(to point: MapPoint) {
        guard point.x.isFinite, point.y.isFinite, var draft = endpointAttachDraft, !isBusy else { return }
        draft.point = point; endpointAttachDraft = draft
        draftMutationGeneration &+= 1; updateDirtyState(); notifyChange()
    }

    func cancelEndpointAttach() {
        guard endpointAttachDraft != nil, !isBusy else { return }
        endpointAttachDraft = nil; draftMutationGeneration &+= 1; updateDirtyState(); notifyChange()
    }

    func finishEndpointAttach(maximumDistance: Double? = nil) async -> Bool {
        guard let draft = endpointAttachDraft else { return false }
        let result: Int? = await mutateResult {
            try $0.attachEndpoint(lineID: draft.lineID, at: draft.point, near: draft.anchor,
                maximumDistance: maximumDistance ?? draft.maximumDistance)
        }
        guard let result else { return false }
        endpointAttachDraft = nil; selectLine(draft.lineID); selectedVertexIndices = [result]; selectedVertexIndex = result
        draftMutationGeneration &+= 1; updateDirtyState(); notifyChange(); return true
    }

    func selectVertex(_ index: Int?, toggle: Bool = false) {
        guard let index else { clearVertexSelection(); notifyChange(); return }
        guard tool == .editVertices, let line = selectedLine, line.points.indices.contains(index) else { return }
        if toggle {
            if selectedVertexIndices.contains(index) { selectedVertexIndices.remove(index) }
            else { selectedVertexIndices.insert(index) }
            selectedVertexIndex = selectedVertexIndices.contains(index) ? index : selectedVertexIndices.sorted().first
        } else {
            selectedVertexIndices = [index]
            selectedVertexIndex = index
        }
        notifyChange()
    }

    func selectVertices(inRectangleFrom first: MapPoint, to second: MapPoint, toggle: Bool = false) {
        guard tool == .editVertices, let line = selectedLine else { return }
        let minX = min(first.x, second.x), maxX = max(first.x, second.x)
        let minY = min(first.y, second.y), maxY = max(first.y, second.y)
        let hits = Set(line.points.indices.filter { index in
            let point = line.points[index]
            return point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
        })
        if toggle { selectedVertexIndices.formSymmetricDifference(hits) }
        else { selectedVertexIndices = hits }
        selectedVertexIndex = selectedVertexIndices.sorted().first
        notifyChange()
    }

    func appendDrawingPoint(_ point: MapPoint) {
        guard tool == .drawLine, !isBusy, isEditAllowed, point.x.isFinite, point.y.isFinite else { return }
        if previewPoints.last != point {
            previewPoints.append(point); draftMutationGeneration &+= 1
            updateDirtyState(); notifyChange()
        }
    }

    func cancelDrawing() {
        guard !isBusy, isEditAllowed else { return }
        if !previewPoints.isEmpty { draftMutationGeneration &+= 1 }
        previewPoints = []; updateDirtyState(); notifyChange()
    }

    func finishDrawing(name: String? = nil) async -> Bool {
        guard previewPoints.count >= 2, endpointAttachDraft == nil, !isBusy, isEditAllowed, let drawing = document,
              let scope = currentScope, let sourceRevision = currentSourceRevision else { return false }
        let capturedPoints = previewPoints
        let capturedDraftGeneration = draftMutationGeneration
        isBusy = true; notifyChange()
        let sourceVerified = await verifyCurrentSource()
        isBusy = false; notifyChange()
        guard sourceVerified, !Task.isCancelled, isEditAllowed, currentScope == scope, currentSourceRevision == sourceRevision,
              draftMutationGeneration == capturedDraftGeneration, previewPoints == capturedPoints,
              !isSourceStale, !isBusy else {
            if !isEditAllowed { showSharedEditGateError() }
            return false
        }
        var next = drawing
        do {
            pushUndo(drawing)
            let id = try next.addLine(points: previewPoints, name: name)
            document = next; lines = next.lines; selectedLineID = id; selectedLineIDs = [id]; clearVertexSelection()
            previewPoints = []; draftMutationGeneration &+= 1
            updateDirtyState(); notifyChange(); return true
        } catch {
            removeLastUndoIfEqual(to: drawing)
            errorMessage = error.localizedDescription; notifyChange(); return false
        }
    }

    func pasteCopiedPolylines(system: any WorkspaceSystemServices,
                              destinationProjectionWKT: String?) async -> Bool {
        do {
            let payload = try GeoprocessingPolylineClipboard.read(system: system)
            return await pasteClipboardLines(payload, destinationProjectionWKT: destinationProjectionWKT)
        } catch {
            errorMessage = error.localizedDescription; notifyChange(); return false
        }
    }

    func pasteClipboardLines(_ payload: GeoprocessingPolylineClipboard,
                             destinationProjectionWKT: String?) async -> Bool {
        do { try payload.validate() }
        catch { errorMessage = error.localizedDescription; notifyChange(); return false }
        guard supportsAddingLines else {
            errorMessage = "Paste copied lines requires a GeoJSON FeatureCollection."; notifyChange(); return false
        }
        guard payload.coordinateProjectionWKT == destinationProjectionWKT else {
            errorMessage = "Copied lines use a different or unknown map projection; paste was refused."; notifyChange(); return false
        }

        let typedLines: [([MapSourceCoordinate], Bool, Bool)]
        do {
            typedLines = try payload.lines.map { line in
                guard !line.hasM || line.hasZ else {
                    throw ProjectFileError.invalid("GeoJSON cannot preserve an M-only clipboard line as an M ordinate.")
                }
                let coordinates = try line.vertices.map { vertex -> MapSourceCoordinate in
                    let z = try Self.clipboardOrdinate(vertex.z, required: line.hasZ)
                    let m = try Self.clipboardOrdinate(vertex.m, required: line.hasM)
                    return MapSourceCoordinate(x: vertex.x, y: vertex.y, z: z, m: m)
                }
                return (coordinates, line.hasZ, line.hasM)
            }
        } catch {
            errorMessage = error.localizedDescription; notifyChange(); return false
        }

        let insertedIDs: [String]? = await mutateResult { document in
            try typedLines.map { line in
                try document.addLine(sourceCoordinates: line.0, hasZ: line.1, hasM: line.2)
            }
        }
        guard let insertedIDs else { return false }
        selectedLineIDs = Set(insertedIDs)
        selectedLineID = insertedIDs.last
        openedLineID = nil; clearVertexSelection(); tool = .select
        notifyChange(); return true
    }

    /// Applies the source In Place handler to this exact GeoJSON editor. The
    /// captured layer/path/revision/draft gates prevent a completed backend
    /// operation from replacing a different source or a newer local edit.
    @discardableResult
    func replaceGeoprocessingLinesInPlace(
        mapID: UUID,
        layerID: String,
        canonicalSourcePath: String,
        sourceRevision: String,
        draftGeneration: String,
        capturedPathIdentities: [String],
        outputs: [GeoprocessingPolylineOutput]
    ) async -> Bool {
        let canonicalPath = SourceFilePaths.canonical(URL(fileURLWithPath: canonicalSourcePath))
        guard let scope = currentScope,
              scope.layerID == layerID,
              scope.canonicalPath == canonicalPath,
              scope.mapID == mapID,
              currentSourceRevision?.caseInsensitiveCompare(sourceRevision) == .orderedSame,
              self.draftGeneration == draftGeneration,
              !isBusy, !isSourceStale, isEditAllowed,
              !capturedPathIdentities.isEmpty,
              Set(capturedPathIdentities).count == capturedPathIdentities.count,
              Set(capturedPathIdentities).isSubset(of: Set(lines.map(\.id))) else {
            errorMessage = "The captured source or line draft no longer matches the active line editor."
            notifyChange(); return false
        }

        if shapefileDraft != nil {
            return await replaceShapefileGeoprocessingLinesInPlace(
                capturedPathIdentities: capturedPathIdentities, outputs: outputs)
        }

        let replacements: [GeoJSONPolylineReplacement]
        do {
            replacements = try outputs.map { output in
                guard output.coordinates.count >= 2,
                      output.coordinates.allSatisfy({ $0.count == 2 && $0[0].isFinite && $0[1].isFinite }) else {
                    throw ProjectFileError.invalid("The backend returned invalid line coordinates.")
                }
                let hasZ = output.zValues != nil
                let hasM = output.mValues != nil
                guard output.zValues.map({ $0.count == output.coordinates.count }) ?? true,
                      output.mValues.map({ $0.count == output.coordinates.count }) ?? true else {
                    throw ProjectFileError.invalid("The backend returned coordinate dimensions with the wrong vertex count.")
                }
                let zValues = try output.zValues.map { try Self.parseFiniteOrdinates($0) }
                let mValues = try output.mValues.map { try Self.parseFiniteOrdinates($0) }
                let coordinates = output.coordinates.indices.map { index -> MapSourceCoordinate in
                    let z = zValues.map { $0[index] }
                    let m = mValues.map { $0[index] }
                    return MapSourceCoordinate(x: output.coordinates[index][0], y: output.coordinates[index][1], z: z, m: m)
                }
                return GeoJSONPolylineReplacement(coordinates: coordinates, hasZ: hasZ, hasM: hasM)
            }
        } catch {
            errorMessage = error.localizedDescription; notifyChange(); return false
        }

        let resultingIDs: [String]? = await mutateResult { document in
            try document.replacePolylines(lineIDs: capturedPathIdentities, with: replacements)
        }
        guard let resultingIDs else { return false }
        selectedLineIDs = Set(resultingIDs)
        selectedLineID = resultingIDs.first
        clearVertexSelection(); openedLineID = nil; tool = .select
        notifyChange(); return true
    }

    private func replaceShapefileGeoprocessingLinesInPlace(
        capturedPathIdentities: [String], outputs: [GeoprocessingPolylineOutput]
    ) async -> Bool {
        guard !isBusy, !isSourceStale, isEditAllowed,
              let draft = shapefileDraft,
              !capturedPathIdentities.isEmpty,
              Set(capturedPathIdentities).count == capturedPathIdentities.count else {
            return false
        }
        let currentLines = draft.records.filter { !$0.isNullRecord }
        let currentIDs = currentLines.compactMap(\.lineID)
        guard currentIDs.count == currentLines.count,
              Set(currentIDs).count == currentIDs.count,
              Set(capturedPathIdentities).isSubset(of: Set(currentIDs)) else {
            errorMessage = PolylineMapEditingError.unsupportedShapefileDraft.localizedDescription
            notifyChange(); return false
        }
        let capturedDraftGeneration = draftMutationGeneration
        isBusy = true; notifyChange()
        let sourceVerified = await verifyCurrentSource()
        isBusy = false; notifyChange()
        guard sourceVerified, !Task.isCancelled, isEditAllowed, !isSourceStale,
              currentScope?.canonicalPath == draft.family.sourcePath,
              draftMutationGeneration == capturedDraftGeneration,
              !isBusy, var latest = shapefileDraft else {
            if !isEditAllowed { showSharedEditGateError() }
            return false
        }

        let oneForSelection = !capturedPathIdentities.isEmpty && outputs.count == capturedPathIdentities.count
        let oneForLayer = outputs.count == currentLines.count
        let replacementTargets = oneForSelection ? capturedPathIdentities :
            (oneForLayer ? currentIDs : (capturedPathIdentities.isEmpty ? currentIDs : capturedPathIdentities))
        guard !replacementTargets.isEmpty else { return false }

        do {
            let parsedOutputs = try outputs.map { output -> ([MapPoint], [MapSourceCoordinate]) in
                guard output.coordinates.count >= 2,
                      output.coordinates.allSatisfy({ $0.count == 2 && $0[0].isFinite && $0[1].isFinite }),
                      output.zValues.map({ $0.count == output.coordinates.count }) ?? true,
                      output.mValues.map({ $0.count == output.coordinates.count }) ?? true else {
                    throw ProjectFileError.invalid("The backend returned invalid line coordinates or dimensions.")
                }
                let z = try output.zValues.map(Self.parseFiniteOrdinates)
                let m = try output.mValues.map(Self.parseFiniteOrdinates)
                let original = latest.records.first { $0.lineID == output.pathIdentity }
                let preservedZ: [Double]?
                if let z {
                    preservedZ = z
                } else if latest.hasZ, let original,
                          original.points.count == output.coordinates.count,
                          original.sourceCoordinates.allSatisfy({ $0.z?.isFinite == true }) {
                    preservedZ = original.sourceCoordinates.compactMap(\.z)
                } else {
                    preservedZ = nil
                }
                let preservedM: [Double]?
                if let m {
                    preservedM = m
                } else if latest.hasM, let original,
                          original.points.count == output.coordinates.count,
                          original.sourceCoordinates.allSatisfy({ $0.m?.isFinite == true }) {
                    preservedM = original.sourceCoordinates.compactMap(\.m)
                } else {
                    preservedM = nil
                }
                if latest.hasZ && preservedZ == nil || latest.hasM && preservedM == nil {
                    throw ProjectFileError.invalid("This Shapefile result would discard source Z or M coordinates.")
                }
                let points = output.coordinates.map { MapPoint(x: $0[0], y: $0[1]) }
                let sourcePoints = output.coordinates.indices.map { index in
                    MapSourceCoordinate(x: output.coordinates[index][0], y: output.coordinates[index][1],
                        z: preservedZ.map { $0[index] }, m: preservedM.map { $0[index] })
                }
                return (points, sourcePoints)
            }

            let indexByID = Dictionary(uniqueKeysWithValues: latest.records.enumerated().compactMap { index, record in
                record.lineID.map { ($0, index) }
            })
            let attributeColumns = latest.records.first(where: { !$0.attributeColumns.isEmpty })?.attributeColumns ?? []
            var resultingIDs: [String] = []
            if oneForSelection || oneForLayer {
                let targets = oneForSelection ? capturedPathIdentities : currentIDs
                for (targetID, output) in zip(targets, parsedOutputs) {
                    guard let index = indexByID[targetID] else { throw PolylineMapEditingError.unsupportedShapefileDraft }
                    var record = latest.records[index]
                    record.points = output.0
                    record.sourceCoordinates = output.1
                    resultingIDs.append(targetID)
                    latest.records[index] = record
                }
            } else {
                let targetSet = Set(replacementTargets)
                latest.records.removeAll { record in
                    record.lineID.map(targetSet.contains) ?? false
                }
                for output in parsedOutputs {
                    let identity = "shapefile-generated-path:\(UUID().uuidString.lowercased())"
                    let feature = identity
                    let defaults = Self.emptyAttributes(for: attributeColumns)
                    latest.records.append(ShapefilePolylineDraftRecord(
                        lineID: identity, sourceFeatureIdentity: feature, sourcePartOrdinal: nil,
                        attributeSourceFeatureIndex: nil, points: output.0, sourceCoordinates: output.1,
                        displayAttributes: defaults.display, attributeColumns: defaults.columns,
                        isNullRecord: false))
                    resultingIDs.append(identity)
                }
            }
            guard latest.records.filter({ !$0.isNullRecord }).allSatisfy({ $0.points.count >= 2 }) else {
                throw ProjectFileError.invalid("The Shapefile line draft contains a line without enough vertices.")
            }
            shapefileUndoStack.append(shapefileSnapshot(draft))
            if shapefileUndoStack.count > 100 { shapefileUndoStack.removeFirst(shapefileUndoStack.count - 100) }
            shapefileRedoStack = []
            latest.records = Self.reindexedForDraft(latest.records)
            shapefileDraft = latest
            lines = Self.lines(from: latest.records, sourceName: latest.sourceLayer.name,
                               revision: currentSourceRevision ?? "")
            selectedLineIDs = Set(resultingIDs)
            selectedLineID = resultingIDs.first
            clearVertexSelection(); openedLineID = nil; tool = .select
            draftMutationGeneration &+= 1
            updateDirtyState(); errorMessage = nil; notifyChange(); return true
        } catch {
            errorMessage = error.localizedDescription; notifyChange(); return false
        }
    }

    private static func parseFiniteOrdinates(_ values: [String]) throws -> [Double] {
        try values.map { text in
            guard let value = Double(text), value.isFinite else {
                throw ProjectFileError.invalid("The backend returned a non-finite coordinate dimension.")
            }
            return value
        }
    }

    private static func clipboardOrdinate(_ value: String?, required: Bool) throws -> Double? {
        guard required else {
            guard value == nil else { throw ProjectFileError.invalid("Clipboard Z/M dimensions do not match the copied coordinates.") }
            return nil
        }
        guard let value, let number = Double(value), number.isFinite else {
            throw ProjectFileError.invalid("GeoJSON cannot store non-finite clipboard Z/M ordinates.")
        }
        return number
    }

    func moveVertex(lineID: String, vertexIndex: Int, to point: MapPoint) async -> Bool {
        await mutate { try $0.moveVertex(lineID: lineID, vertexIndex: vertexIndex, to: point) }
    }

    func moveVertices(lineID: String, vertexIndices: Set<Int>, by delta: MapPoint,
                      duplicateTolerance: Double, interactionPoint: MapPoint) async -> Bool {
        guard tool == .editVertices, selectedLineID == lineID, selectedVertexIndices == vertexIndices,
              !vertexIndices.isEmpty else { return false }
        let movedSelection: [Int]? = await mutateResult {
            try $0.moveVertices(lineID: lineID, vertexIndices: vertexIndices, by: delta,
                duplicateTolerance: duplicateTolerance, interactionPoint: interactionPoint)
        }
        guard let movedSelection else { return false }
        selectedVertexIndices = Set(movedSelection)
        selectedVertexIndex = movedSelection.first
        notifyChange(); return true
    }

    func insertVertex(lineID: String, after vertexIndex: Int, at point: MapPoint) async -> Bool {
        guard selectedLineID == lineID else { return false }
        let insertedIndex = vertexIndex + 1
        let succeeded = await mutate { try $0.insertVertex(lineID: lineID, after: vertexIndex, at: point) }
        if succeeded {
            selectedVertexIndices = [insertedIndex]
            selectedVertexIndex = insertedIndex
            notifyChange()
        }
        return succeeded
    }

    func deleteSelectedVertex() async -> Bool { await deleteSelectedVertices() }

    func deleteSelectedVertices() async -> Bool {
        guard tool == .editVertices, let lineID = selectedLineID, !selectedVertexIndices.isEmpty else { return false }
        let selected = selectedVertexIndices
        let result: GeoJSONPolylinePointDeletion? = await mutateResult {
            try $0.deleteVertices(lineID: lineID, vertexIndices: selected)
        }
        guard let result else { return false }
        if result.lineDeleted {
            if selectedLineID == lineID {
                selectedLineID = nil; selectedLineIDs.remove(lineID); openedLineID = nil
            }
            clearVertexSelection()
        } else if let selectedIndex = result.selectedVertexIndex {
            selectedVertexIndices = [selectedIndex]; selectedVertexIndex = selectedIndex
        } else {
            clearVertexSelection()
        }
        notifyChange(); return true
    }

    func deleteSelectedLine() async -> Bool {
        guard let lineID = selectedLineID else { return false }
        let succeeded = await mutate { try $0.deleteLine(lineID: lineID) }
        if succeeded { selectedLineID = nil; selectedLineIDs = []; clearVertexSelection(); openedLineID = nil; notifyChange() }
        return succeeded
    }

    func reverseSelectedLine() async -> Bool {
        guard let lineID = selectedLineID else { return false }
        return await mutate { try $0.reverse(lineID: lineID) }
    }

    func filterSelectedLine(epsilon: Double) async -> Bool {
        guard epsilon.isFinite, epsilon > 0 else {
            errorMessage = "Filter tolerance must be finite and positive."
            notifyChange(); return false
        }
        return await applyXYGeoprocessing(operation: .filter, epsilon: epsilon)
    }

    func smoothSelectedLine(windowSize: Int, iterations: Int) async -> Bool {
        guard (1...101).contains(windowSize), (0...20).contains(iterations) else {
            errorMessage = "Smooth window and passes are outside the supported range."
            notifyChange(); return false
        }
        return await applyXYGeoprocessing(operation: .smooth, windowSize: windowSize, iterations: iterations)
    }

    private func applyXYGeoprocessing(operation: PolylineGeoprocessOperation,
                                      epsilon: Double? = nil,
                                      windowSize: Int? = nil,
                                      iterations: Int? = nil) async -> Bool {
        guard !isBusy, !isSourceStale, isEditAllowed,
              let selectedLineID, let selectedLine = lines.first(where: { $0.id == selectedLineID }), selectedLine.canEdit,
              let current = document, let scope = currentScope,
              let sourceRevision = currentSourceRevision else { return false }

        let coordinates: [[Double]]
        do { coordinates = try current.xyCoordinates(lineID: selectedLineID) }
        catch { errorMessage = error.localizedDescription; notifyChange(); return false }
        guard coordinates.count <= Self.maximumGeoprocessVertexCount else {
            errorMessage = "Filter and Smooth support at most 10,000 vertices per operation."
            notifyChange(); return false
        }
        let request = PolylineGeoprocessRequest(operation: operation, coordinates: coordinates,
            epsilon: epsilon, windowSize: windowSize, iterations: iterations)
        let capturedGeneration = generation
        let capturedDraftGeneration = draftMutationGeneration
        let capturedDraftIdentity = draftGeneration
        isBusy = true; notifyChange()

        let sourceVerified = await verifyCurrentSource()
        guard sourceVerified, !Task.isCancelled, isEditAllowed, !isSourceStale,
              generation == capturedGeneration, currentScope == scope,
              currentSourceRevision == sourceRevision, draftMutationGeneration == capturedDraftGeneration,
              draftGeneration == capturedDraftIdentity, self.selectedLineID == selectedLineID else {
            isBusy = false; notifyChange()
            if !isEditAllowed { showSharedEditGateError() }
            return false
        }

        do {
            let transformed = try await geoprocessProvider.transform(request)
            guard !Task.isCancelled, generation == capturedGeneration, currentScope == scope,
                  currentSourceRevision == sourceRevision, draftMutationGeneration == capturedDraftGeneration,
                  draftGeneration == capturedDraftIdentity, self.selectedLineID == selectedLineID,
                  isEditAllowed, !isSourceStale else {
                isBusy = false; notifyChange()
                if !isEditAllowed { showSharedEditGateError() }
                return false
            }

            let actualRevision = try await provider.revision(scope: scope)
            guard actualRevision == sourceRevision else {
                isSourceStale = true
                errorMessage = PolylineMapEditingError.sourceChanged.localizedDescription
                isBusy = false; notifyChange(); return false
            }
            guard !Task.isCancelled, generation == capturedGeneration, currentScope == scope,
                  currentSourceRevision == sourceRevision, draftMutationGeneration == capturedDraftGeneration,
                  draftGeneration == capturedDraftIdentity, self.selectedLineID == selectedLineID,
                  isEditAllowed, !isSourceStale, let latest = document else {
                isBusy = false; notifyChange()
                if !isEditAllowed { showSharedEditGateError() }
                return false
            }

            var updated = latest
            try updated.replaceXYCoordinates(lineID: selectedLineID, coordinates: transformed.coordinates)
            guard try updated.encoded() != (try latest.encoded()) else {
                isBusy = false; notifyChange(); return false
            }
            pushUndo(latest); redoStack = []; document = updated; lines = updated.lines
            normalizeVertexSelection(); draftMutationGeneration &+= 1
            updateDirtyState(); errorMessage = nil; isBusy = false; notifyChange()
            return true
        } catch {
            isBusy = false
            errorMessage = error.localizedDescription
            notifyChange(); return false
        }
    }

    func undo() async -> Bool {
        guard !isBusy, isEditAllowed else { return false }
        if !previewPoints.isEmpty { cancelDrawing(); return true }
        if endpointAttachDraft != nil { cancelEndpointAttach(); return true }
        if shapefileDraft != nil { return await undoShapefileDraft() }
        guard !undoStack.isEmpty, let current = document, let scope = currentScope,
              let sourceRevision = currentSourceRevision else { return false }
        let capturedDraftGeneration = draftMutationGeneration
        isBusy = true; notifyChange()
        let sourceVerified = await verifyCurrentSource()
        isBusy = false; notifyChange()
        guard sourceVerified, !Task.isCancelled, isEditAllowed, currentScope == scope, currentSourceRevision == sourceRevision,
              draftMutationGeneration == capturedDraftGeneration, !isSourceStale, !isBusy,
              let previous = undoStack.popLast() else {
            if !isEditAllowed { showSharedEditGateError() }
            return false
        }
        redoStack.append(snapshot(document: current)); restore(previous); draftMutationGeneration &+= 1
        updateDirtyState(); notifyChange(); return true
    }

    func redo() async -> Bool {
        if shapefileDraft != nil { return await redoShapefileDraft() }
        guard !isBusy, isEditAllowed, !redoStack.isEmpty,
              let current = document, let scope = currentScope,
              let sourceRevision = currentSourceRevision else { return false }
        let capturedDraftGeneration = draftMutationGeneration
        isBusy = true; notifyChange()
        let sourceVerified = await verifyCurrentSource()
        isBusy = false; notifyChange()
        guard sourceVerified, !Task.isCancelled, isEditAllowed, currentScope == scope, currentSourceRevision == sourceRevision,
              draftMutationGeneration == capturedDraftGeneration, !isSourceStale, !isBusy,
              let next = redoStack.popLast() else {
            if !isEditAllowed { showSharedEditGateError() }
            return false
        }
        undoStack.append(snapshot(document: current)); restore(next); draftMutationGeneration &+= 1
        updateDirtyState(); notifyChange(); return true
    }

    func save() async -> Bool {
        if shapefileDraft != nil { return await saveShapefileDraft() }
        guard !isBusy, isSaveAllowed, hasUnsavedChanges, let scope = currentScope,
              let expectedRevision = currentSourceRevision else { return false }
        guard previewPoints.isEmpty else {
            errorMessage = "Finish or cancel the line drawing before saving."
            notifyChange(); return false
        }
        guard endpointAttachDraft == nil else {
            errorMessage = "Apply or cancel the endpoint preview before saving."
            notifyChange(); return false
        }
        let capturedDraftGeneration = draftMutationGeneration
        isBusy = true; notifyChange()
        let sourceVerified = await verifyCurrentSource()
        isBusy = false; notifyChange()
        guard sourceVerified, !Task.isCancelled, isSaveAllowed, hasUnsavedChanges, currentScope == scope,
              currentSourceRevision == expectedRevision, draftMutationGeneration == capturedDraftGeneration,
              previewPoints.isEmpty, endpointAttachDraft == nil, !isSourceStale, !isBusy, let source = document else {
            if !isSaveAllowed { showSharedEditGateError() }
            return false
        }
        generation &+= 1
        let operation = generation
        let capturedData: Data
        do { capturedData = try source.encoded() }
        catch { errorMessage = error.localizedDescription; notifyChange(); return false }
        isBusy = true; notifyChange()
        defer { if generation == operation { isBusy = false; notifyChange() } }
        do {
            let newRevision = try await provider.save(scope: scope, expectedRevision: expectedRevision, data: capturedData)
            // The provider has committed the captured bytes. A late task cancellation
            // must not leave this already-saved draft dirty and replay it on the next save.
            guard generation == operation, currentScope == scope else { return false }
            var saved = source
            saved.acceptSavedRevision(newRevision)
            document = saved; currentSourceRevision = newRevision
            baseline = try saved.encoded(); lines = saved.lines; hasUnsavedChanges = false
            draftMutationGeneration &+= 1
            undoStack = []; redoStack = []; isSourceStale = false; errorMessage = nil
            notifyChange(); return true
        } catch {
            guard generation == operation else { return false }
            if error is PolylineMapEditingError { isSourceStale = true }
            errorMessage = error.localizedDescription; notifyChange(); return false
        }
    }

    func discard() async -> Bool {
        guard !isBusy, let scope = currentScope else { return false }
        if let draft = shapefileDraft { return await discardShapefileDraft(draft, scope: scope) }
        generation &+= 1
        let operation = generation
        isBusy = true; notifyChange()
        defer { if generation == operation { isBusy = false; notifyChange() } }
        do {
            let loaded = try await provider.load(scope: scope)
            guard generation == operation, currentScope == scope, !Task.isCancelled else { return false }
            document = loaded; currentSourceRevision = loaded.sourceRevision; baseline = try loaded.encoded()
            lines = loaded.lines; selectedLineID = nil; selectedLineIDs = []; clearVertexSelection(); openedLineID = nil; previewPoints = []; endpointAttachDraft = nil
            hasUnsavedChanges = false; isSourceStale = false; undoStack = []; redoStack = []; errorMessage = nil
            draftMutationGeneration &+= 1
            notifyChange(); return true
        } catch {
            guard generation == operation else { return false }
            errorMessage = error.localizedDescription; notifyChange(); return false
        }
    }

    private func undoShapefileDraft() async -> Bool {
        guard !isBusy, isEditAllowed, !shapefileUndoStack.isEmpty,
              shapefileDraft != nil, let scope = currentScope else { return false }
        let capturedGeneration = draftMutationGeneration
        isBusy = true; notifyChange()
        let sourceVerified = await verifyCurrentSource()
        isBusy = false; notifyChange()
        guard sourceVerified, !Task.isCancelled, isEditAllowed, currentScope == scope,
              draftMutationGeneration == capturedGeneration, !isSourceStale, !isBusy,
              var latest = shapefileDraft, let previous = shapefileUndoStack.popLast() else {
            if !isEditAllowed { showSharedEditGateError() }
            return false
        }
        shapefileRedoStack.append(shapefileSnapshot(latest))
        latest.records = previous.records
        shapefileDraft = latest
        restoreShapefileSelection(previous)
        draftMutationGeneration &+= 1; updateDirtyState(); notifyChange(); return true
    }

    private func redoShapefileDraft() async -> Bool {
        guard !isBusy, isEditAllowed, !shapefileRedoStack.isEmpty,
              shapefileDraft != nil, let scope = currentScope else { return false }
        let capturedGeneration = draftMutationGeneration
        isBusy = true; notifyChange()
        let sourceVerified = await verifyCurrentSource()
        isBusy = false; notifyChange()
        guard sourceVerified, !Task.isCancelled, isEditAllowed, currentScope == scope,
              draftMutationGeneration == capturedGeneration, !isSourceStale, !isBusy,
              var latest = shapefileDraft, let next = shapefileRedoStack.popLast() else {
            if !isEditAllowed { showSharedEditGateError() }
            return false
        }
        shapefileUndoStack.append(shapefileSnapshot(latest))
        latest.records = next.records
        shapefileDraft = latest
        restoreShapefileSelection(next)
        draftMutationGeneration &+= 1; updateDirtyState(); notifyChange(); return true
    }

    private func saveShapefileDraft() async -> Bool {
        guard !isBusy, isSaveAllowed, hasUnsavedChanges,
              let scope = currentScope, var draft = shapefileDraft,
              previewPoints.isEmpty, endpointAttachDraft == nil,
              !isSourceStale else { return false }
        let capturedDraftGeneration = draftMutationGeneration
        isBusy = true; notifyChange()
        let latestFamily: MapSourceFamilyCapture
        do {
            latestFamily = try await shapefileProvider.captureFamily(sourcePath: scope.canonicalPath)
        } catch {
            isBusy = false; isSourceStale = true; errorMessage = error.localizedDescription; notifyChange(); return false
        }
        guard latestFamily == draft.family, !Task.isCancelled, isSaveAllowed,
              currentScope == scope, draftMutationGeneration == capturedDraftGeneration,
              !isSourceStale else {
            isBusy = false; isSourceStale = latestFamily != draft.family
            if isSourceStale { errorMessage = PolylineMapEditingError.sourceChanged.localizedDescription }
            notifyChange(); return false
        }
        let records = draft.records.map { record in
            PolylineShapefileDraftSaveRecord(
                attributeSourceFeatureIndex: record.attributeSourceFeatureIndex,
                coordinates: record.points.map { [$0.x, $0.y] },
                zValues: Self.ordinateStrings(record.sourceCoordinates, keyPath: \.z),
                mValues: Self.ordinateStrings(record.sourceCoordinates, keyPath: \.m))
        }
        generation &+= 1
        let operation = generation
        do {
            let receipt = try await shapefileProvider.save(scope: scope,
                projectionStatus: draft.projectionStatus,
                sourceProjectionWKT: draft.sourceLayer.sourceProjectionWKT,
                targetProjectionWKT: draft.sourceLayer.targetProjectionWKT,
                expectedFamily: draft.family, records: records)
            guard generation == operation, currentScope == scope,
                  receipt.records.count == draft.records.count else {
                isBusy = false
                isSourceStale = true
                errorMessage = "The Shapefile was saved, but its editor response could not be matched. Reload the map layer before continuing."
                notifyChange()
                return false
            }
            let sourceRevision = Self.sourceRevision(receipt.family)
            guard let sourceRevision else { throw PolylineMapEditingError.sourceChanged }
            var savedRecords: [ShapefilePolylineDraftRecord] = []
            savedRecords.reserveCapacity(draft.records.count)
            for (index, tuple) in zip(draft.records, receipt.records) {
                let identity = Self.shapefileRecordIdentity(index: tuple.recordIndex, revision: sourceRevision)
                let lineID = index.isNullRecord ? nil : identity + "|part:0"
                let coordinates = try tuple.sourceCoordinates.map { coordinate -> MapSourceCoordinate in
                    guard coordinate.count == 2, coordinate[0].isFinite, coordinate[1].isFinite else {
                        throw BackendServiceError(code: "protocolFailure", message: "The saved Shapefile reply contains invalid source coordinates.")
                    }
                    return MapSourceCoordinate(x: coordinate[0], y: coordinate[1])
                }
                var record = index
                record.lineID = lineID
                record.sourceFeatureIdentity = identity
                record.sourcePartOrdinal = index.isNullRecord ? nil : 0
                record.attributeSourceFeatureIndex = tuple.recordIndex
                record.sourceCoordinates = try Self.coordinatesWithDimensions(
                    coordinates, zValues: tuple.zValues, mValues: tuple.mValues)
                savedRecords.append(record)
            }
            let previousFamily = draft.family
            draft.records = savedRecords
            draft.baselineRecords = savedRecords
            draft.family = receipt.family
            shapefileDraft = draft
            currentSourceRevision = sourceRevision
            lines = Self.lines(from: savedRecords, sourceName: draft.sourceLayer.name, revision: sourceRevision)
            hasUnsavedChanges = false; shapefileUndoStack = []; shapefileRedoStack = []
            selectedLineID = selectedLineIDs.first(where: { id in savedRecords.contains { $0.lineID == id } })
            selectedLineIDs = Set(selectedLineIDs.filter { id in savedRecords.contains { $0.lineID == id } })
            selectedLineID = selectedLineID ?? selectedLineIDs.first
            isSourceStale = false; errorMessage = nil; draftMutationGeneration &+= 1
            let familyPublished = didSaveShapefileFamily?(previousFamily, receipt.family, scope) ?? false
            isBusy = false
            if !familyPublished {
                isSourceStale = true
                errorMessage = "The Shapefile was saved, but the map source revision could not be refreshed. Reopen the map layer before continuing."
            }
            notifyChange(); return true
        } catch {
            if generation == operation {
                isBusy = false
                if error is PolylineMapEditingError || (error as? BackendServiceError)?.code == "sourceChanged" {
                    isSourceStale = true
                }
                errorMessage = error.localizedDescription; notifyChange()
            }
            return false
        }
    }

    private func discardShapefileDraft(_ current: ShapefilePolylineDraft,
                                       scope: PolylineMapEditingScope) async -> Bool {
        let capturedGeneration = draftMutationGeneration
        isBusy = true; notifyChange()
        do {
            let latest = try await shapefileProvider.captureFamily(sourcePath: scope.canonicalPath)
            guard latest == current.family, currentScope == scope,
                  draftMutationGeneration == capturedGeneration, !Task.isCancelled else {
                isBusy = false; isSourceStale = true
                errorMessage = PolylineMapEditingError.sourceChanged.localizedDescription
                notifyChange(); return false
            }
            var restored = current
            restored.records = current.baselineRecords
            shapefileDraft = restored
            currentSourceRevision = Self.sourceRevision(latest)
            lines = Self.lines(from: restored.records, sourceName: restored.sourceLayer.name,
                               revision: currentSourceRevision ?? "")
            selectedLineID = nil; selectedLineIDs = []; clearVertexSelection(); openedLineID = nil
            hasUnsavedChanges = false; isSourceStale = false
            shapefileUndoStack = []; shapefileRedoStack = []; errorMessage = nil
            draftMutationGeneration &+= 1; isBusy = false; notifyChange(); return true
        } catch {
            isBusy = false; isSourceStale = true; errorMessage = error.localizedDescription; notifyChange(); return false
        }
    }

    /// Clears this map-scoped editor after the parent has obtained an explicit
    /// Discard decision. This synchronous path lets project replacement release
    /// the old session before its source file is removed or replaced.
    @discardableResult
    func discardForProjectReplacement() -> Bool {
        guard !isBusy else { return false }
        generation &+= 1
        currentScope = nil; currentSourceRevision = nil; document = nil; shapefileDraft = nil; baseline = nil
        lines = []; previewPoints = []; endpointAttachDraft = nil; selectedLineID = nil; selectedLineIDs = []; clearVertexSelection(); openedLineID = nil
        undoStack = []; redoStack = []; shapefileUndoStack = []; shapefileRedoStack = []
        temporaryToolKey = nil; temporaryToolRestore = nil
        hasUnsavedChanges = false; isSourceStale = false; errorMessage = nil; draftMutationGeneration &+= 1
        notifyChange(); return true
    }

    func handleCanvasInput(_ input: PolylineMapCanvasInput) async {
        switch (tool, input.kind) {
        case (.select, .click): selectLine(input.lineID, additive: input.modifiers.extendsSelection)
        case (.select, .doubleClick):
            if let id = input.lineID { toggleOpenLine(id) }
        case (.drawLine, .click): appendDrawingPoint(input.point)
        case (.drawLine, .doubleClick):
            appendDrawingPoint(input.point)
            _ = await finishDrawing()
        case (.splitLine, .click):
            _ = await splitNearestLine(near: input.point, maximumDistance: input.maximumDistance ?? 0,
                optionToggledMode: input.modifiers.contains(.option))
        case (.mergeLines, .click):
            selectLine(input.lineID, additive: input.modifiers.extendsSelection)
        case (.attachEndpoint, .click):
            if let id = input.lineID ?? selectedLineID {
                _ = await attachEndpoint(lineID: id, at: input.point, maximumDistance: input.maximumDistance ?? 0)
            }
        case (.editVertices, .click):
            if let lineID = input.lineID {
                if selectedLineID != lineID { selectLine(lineID) }
                if let vertex = input.vertexIndex { selectVertex(vertex, toggle: input.modifiers.contains(.control)) }
                else if let segment = input.segmentAfterIndex { _ = await insertVertex(lineID: lineID, after: segment, at: input.point) }
            }
        default: break
        }
    }

    private func mutate(_ operation: (inout GeoJSONPolylineDocument) throws -> Void) async -> Bool {
        let result: Bool? = await mutateResult { document in
            try operation(&document)
            return true
        }
        return result ?? false
    }

    private func mutateResult<T>(_ operation: (inout GeoJSONPolylineDocument) throws -> T) async -> T? {
        guard !isBusy, isEditAllowed, !isSourceStale,
              let current = document, let scope = currentScope,
              let sourceRevision = currentSourceRevision else { return nil }
        let capturedDraftGeneration = draftMutationGeneration
        isBusy = true; notifyChange()
        let sourceVerified = await verifyCurrentSource()
        isBusy = false; notifyChange()
        guard sourceVerified, !Task.isCancelled, isEditAllowed, !isSourceStale, currentScope == scope,
              currentSourceRevision == sourceRevision, draftMutationGeneration == capturedDraftGeneration,
              !isBusy else {
            if !isEditAllowed { showSharedEditGateError() }
            return nil
        }
        var updated = current
        do {
            let result = try operation(&updated)
            guard try updated.encoded() != (try current.encoded()) else { return nil }
            pushUndo(current); redoStack = []; document = updated; lines = updated.lines
            selectedLineIDs = Set(selectedLineIDs.filter { id in lines.contains(where: { $0.id == id }) })
            if !selectedLineIDs.contains(selectedLineID ?? "") {
                selectedLineID = lines.first(where: { selectedLineIDs.contains($0.id) })?.id
            }
            if let openedLineID, !lines.contains(where: { $0.id == openedLineID }) { self.openedLineID = nil }
            normalizeVertexSelection()
            draftMutationGeneration &+= 1
            updateDirtyState(); errorMessage = nil; notifyChange(); return result
        } catch { errorMessage = error.localizedDescription; notifyChange(); return nil }
    }

    private func verifyCurrentSource() async -> Bool {
        guard let scope = currentScope, let expected = currentSourceRevision else {
            errorMessage = PolylineMapEditingError.noDocument.localizedDescription; notifyChange(); return false
        }
        if let draft = shapefileDraft {
            do {
                let actual = try await shapefileProvider.captureFamily(sourcePath: scope.canonicalPath)
                guard !Task.isCancelled, currentScope == scope,
                      currentSourceRevision == expected, shapefileDraft?.family == draft.family else { return false }
                if actual != draft.family || Self.sourceRevision(actual)?.caseInsensitiveCompare(expected) != .orderedSame {
                    isSourceStale = true
                    errorMessage = PolylineMapEditingError.sourceChanged.localizedDescription
                    selectedLineID = nil; selectedLineIDs = []; clearVertexSelection(); openedLineID = nil
                    notifyChange(); return false
                }
                return !isSourceStale
            } catch {
                isSourceStale = true; errorMessage = error.localizedDescription; notifyChange(); return false
            }
        }
        do {
            let actual = try await provider.revision(scope: scope)
            guard !Task.isCancelled, currentScope == scope, currentSourceRevision == expected else { return false }
            if actual != expected {
                isSourceStale = true; errorMessage = PolylineMapEditingError.sourceChanged.localizedDescription
                selectedLineID = nil; selectedLineIDs = []; clearVertexSelection(); openedLineID = nil; notifyChange(); return false
            }
            return !isSourceStale
        } catch {
            isSourceStale = true; errorMessage = error.localizedDescription; notifyChange(); return false
        }
    }

    private func nearestLine(to point: MapPoint, mode: GeoJSONPolylineSplitMode,
                             maximumDistance: Double) -> GeoJSONPolylineLine? {
        guard maximumDistance.isFinite, maximumDistance >= 0 else { return nil }
        return lines.compactMap { line -> (GeoJSONPolylineLine, Double)? in
            guard line.canEdit, line.points.count >= 2 else { return nil }
            let distance: Double
            switch mode {
            case .anywhere:
                distance = Self.distance(to: point, polyline: line.points)
            case .atVertex:
                distance = line.points.dropFirst().dropLast().map { hypot(point.x - $0.x, point.y - $0.y) }.min() ?? .infinity
            }
            return distance <= maximumDistance ? (line, distance) : nil
        }.min { $0.1 < $1.1 }?.0
    }

    private static func distance(to point: MapPoint, polyline: [MapPoint]) -> Double {
        guard polyline.count >= 2 else { return .infinity }
        return (0..<(polyline.count - 1)).map { index in
            distance(to: point, segmentStart: polyline[index], segmentEnd: polyline[index + 1])
        }.min() ?? .infinity
    }

    private static func distance(to point: MapPoint, segmentStart start: MapPoint, segmentEnd end: MapPoint) -> Double {
        let dx = end.x - start.x, dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0, lengthSquared.isFinite else { return hypot(point.x - start.x, point.y - start.y) }
        let fraction = min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (start.x + fraction * dx), point.y - (start.y + fraction * dy))
    }

    private static func polylineIntersectsPolygon(_ line: [MapPoint], polygon: [MapPoint]) -> Bool {
        guard line.count >= 2, polygon.count >= 3 else { return false }
        if line.contains(where: { pointInPolygon($0, polygon: polygon) }) { return true }
        for lineIndex in 0..<(line.count - 1) {
            for polygonIndex in polygon.indices {
                let next = (polygonIndex + 1) % polygon.count
                if segmentsIntersect(line[lineIndex], line[lineIndex + 1], polygon[polygonIndex], polygon[next]) { return true }
            }
        }
        return false
    }

    private static func polylineIsContained(_ line: [MapPoint], polygon: [MapPoint]) -> Bool {
        guard line.count >= 2, polygon.count >= 3,
              line.allSatisfy({ pointInPolygon($0, polygon: polygon) }) else { return false }
        return (0..<(line.count - 1)).allSatisfy { index in
            segmentIsContained(line[index], line[index + 1], polygon: polygon)
        }
    }

    private static func segmentIsContained(_ start: MapPoint, _ end: MapPoint, polygon: [MapPoint]) -> Bool {
        var splitParameters = [0.0, 1.0]
        let rayX = end.x - start.x, rayY = end.y - start.y
        for edgeIndex in polygon.indices {
            let a = polygon[edgeIndex], b = polygon[(edgeIndex + 1) % polygon.count]
            let edgeX = b.x - a.x, edgeY = b.y - a.y
            let denominator = rayX * edgeY - rayY * edgeX
            guard abs(denominator) > 1e-12 else { continue }
            let offsetX = a.x - start.x, offsetY = a.y - start.y
            let t = (offsetX * edgeY - offsetY * edgeX) / denominator
            let u = (offsetX * rayY - offsetY * rayX) / denominator
            if t > 0, t < 1, u >= 0, u <= 1 { splitParameters.append(t) }
        }
        splitParameters.sort()
        for pairIndex in 0..<(splitParameters.count - 1) {
            let t = (splitParameters[pairIndex] + splitParameters[pairIndex + 1]) / 2
            let midpoint = MapPoint(x: start.x + rayX * t, y: start.y + rayY * t)
            if !pointInPolygon(midpoint, polygon: polygon) { return false }
        }
        return true
    }

    private static func polylinesIntersect(_ first: [MapPoint], _ second: [MapPoint]) -> Bool {
        guard first.count >= 2, second.count >= 2 else { return false }
        for firstIndex in 0..<(first.count - 1) {
            for secondIndex in 0..<(second.count - 1) {
                if segmentsIntersect(first[firstIndex], first[firstIndex + 1], second[secondIndex], second[secondIndex + 1]) { return true }
            }
        }
        return false
    }

    private static func segmentsIntersect(_ a: MapPoint, _ b: MapPoint, _ c: MapPoint, _ d: MapPoint) -> Bool {
        let abC = orientation(a, b, c), abD = orientation(a, b, d)
        let cdA = orientation(c, d, a), cdB = orientation(c, d, b)
        if abC == 0 && pointOnSegment(c, a, b) { return true }
        if abD == 0 && pointOnSegment(d, a, b) { return true }
        if cdA == 0 && pointOnSegment(a, c, d) { return true }
        if cdB == 0 && pointOnSegment(b, c, d) { return true }
        return (abC > 0) != (abD > 0) && (cdA > 0) != (cdB > 0)
    }

    private static func orientation(_ a: MapPoint, _ b: MapPoint, _ c: MapPoint) -> Int {
        let cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        let scale = [abs(b.x - a.x), abs(b.y - a.y), abs(c.x - a.x), abs(c.y - a.y), 1].max() ?? 1
        if abs(cross) <= scale * scale * 1e-12 { return 0 }
        return cross < 0 ? -1 : 1
    }

    private static func pointOnSegment(_ point: MapPoint, _ start: MapPoint, _ end: MapPoint) -> Bool {
        point.x >= min(start.x, end.x) - 1e-12 && point.x <= max(start.x, end.x) + 1e-12 &&
        point.y >= min(start.y, end.y) - 1e-12 && point.y <= max(start.y, end.y) + 1e-12
    }

    private static func pointInPolygon(_ point: MapPoint, polygon: [MapPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon.count - 1
        for current in polygon.indices {
            let a = polygon[previous], b = polygon[current]
            if orientation(a, b, point) == 0 && pointOnSegment(point, a, b) { return true }
            if (a.y > point.y) != (b.y > point.y) {
                let crossingX = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
                if point.x < crossingX { inside.toggle() }
            }
            previous = current
        }
        return inside
    }

    private func updateDirtyState() {
        if let shapefileDraft {
            hasUnsavedChanges = !previewPoints.isEmpty || endpointAttachDraft != nil
                || shapefileDraft.records != shapefileDraft.baselineRecords
            return
        }
        guard let document, let baseline else {
            hasUnsavedChanges = !previewPoints.isEmpty || endpointAttachDraft != nil
            return
        }
        hasUnsavedChanges = !previewPoints.isEmpty || endpointAttachDraft != nil || (try? document.encoded()) != baseline
    }

    private func clearVertexSelection() {
        selectedVertexIndex = nil
        selectedVertexIndices = []
    }

    private static func makeShapefileDraft(layer: MapVectorLayer, scope: PolylineMapEditingScope,
                                           family: MapSourceFamilyCapture) throws -> ShapefilePolylineDraft {
        let sourceRevision = layer.sourceRevision ?? ""
        let normalized = try MapShapefileVectorConverter.validateFamily(family,
            sourcePath: scope.canonicalPath, sourceRevision: sourceRevision)
        guard layer.url.pathExtension.lowercased() == "shp",
              layer.id == scope.layerID,
              SourceFilePaths.canonical(layer.url) == scope.canonicalPath,
              layer.sourceMapID == nil || layer.sourceMapID == scope.mapID,
              layer.features.allSatisfy({ $0.kind == .line }) else {
            throw PolylineMapEditingError.invalidScope
        }

        var records: [ShapefilePolylineDraftRecord] = []
        var seenSourceOrdinals = Set<Int>()
        var seenPathIDs = Set<String>()
        var sawZ = false
        var sawM = false
        for feature in layer.features {
            guard feature.hasUniqueStableIdentity,
                  let sourceOrdinal = feature.sourceFeatureIndex, sourceOrdinal >= 0,
                  seenSourceOrdinals.insert(sourceOrdinal).inserted,
                  let sourcePaths = feature.sourceCoordinatePaths,
                  sourcePaths.count == feature.paths.count else {
                throw PolylineMapEditingError.unsupportedShapefileDraft
            }
            let columns = feature.sourceAttributeColumns ?? []
            if feature.paths.isEmpty {
                records.append(ShapefilePolylineDraftRecord(lineID: nil,
                    sourceFeatureIdentity: feature.stableIdentity, sourcePartOrdinal: nil,
                    attributeSourceFeatureIndex: sourceOrdinal, points: [], sourceCoordinates: [],
                    displayAttributes: feature.attributes, attributeColumns: columns, isNullRecord: true))
                continue
            }
            guard feature.pathStableIdentities.count == feature.paths.count,
                  sourcePaths.count == feature.paths.count else {
                throw PolylineMapEditingError.unsupportedShapefileDraft
            }
            for pathIndex in feature.paths.indices {
                let points = feature.paths[pathIndex]
                let sourceCoordinates = sourcePaths[pathIndex]
                let pathID = feature.pathStableIdentities[pathIndex]
                guard !pathID.isEmpty, seenPathIDs.insert(pathID).inserted,
                      points.count >= 2, points.count == sourceCoordinates.count,
                      points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                      sourceCoordinates.allSatisfy({ $0.x.isFinite && $0.y.isFinite
                          && ($0.z.map(\.isFinite) ?? true) && ($0.m.map(\.isFinite) ?? true) }) else {
                    throw PolylineMapEditingError.unsupportedShapefileDraft
                }
                sawZ = sawZ || sourceCoordinates.contains { $0.z != nil }
                sawM = sawM || sourceCoordinates.contains { $0.m != nil }
                records.append(ShapefilePolylineDraftRecord(lineID: pathID,
                    sourceFeatureIdentity: feature.stableIdentity, sourcePartOrdinal: pathIndex,
                    attributeSourceFeatureIndex: sourceOrdinal, points: points,
                    sourceCoordinates: sourceCoordinates, displayAttributes: feature.attributes,
                    attributeColumns: columns, isNullRecord: false))
            }
        }
        let projectionStatus = layer.targetProjectionWKT == nil
            ? "localProjectSourceCoordinates" : "projected"
        return ShapefilePolylineDraft(sourceLayer: layer, family: normalized, records: records,
            baselineRecords: records, projectionStatus: projectionStatus, hasZ: sawZ, hasM: sawM)
    }

    private static func sourceRevision(_ family: MapSourceFamilyCapture) -> String? {
        family.files.first(where: { $0.role == "source" && $0.required })?.revision
    }

    private static func shapefileRecordIdentity(index: Int, revision: String) -> String {
        "shapefile-record:\(index):sha256:\(revision.uppercased())"
    }

    private static func lines(from records: [ShapefilePolylineDraftRecord], sourceName: String,
                              revision: String) -> [GeoJSONPolylineLine] {
        records.enumerated().compactMap { index, record in
            guard !record.isNullRecord, let id = record.lineID else { return nil }
            let name = record.displayAttributes["name"] ?? "\(sourceName) \(index + 1)"
            return GeoJSONPolylineLine(id: id, sourceFeatureIdentity: record.sourceFeatureIdentity,
                sourceFeatureOrdinal: index, componentOrdinal: record.sourcePartOrdinal ?? 0,
                name: name, points: record.points, geometryPath: "shape.parts", canEdit: true)
        }
    }

    private static func mapFeatures(for records: [ShapefilePolylineDraftRecord]) -> [MapFeature] {
        records.enumerated().map { index, record in
            let sourceAttributes = Dictionary(record.attributeColumns.map { ($0.name, $0.value) },
                uniquingKeysWith: { _, last in last })
            let paths = record.isNullRecord ? [] : [record.points]
            let sourcePaths = record.isNullRecord ? [] : [record.sourceCoordinates]
            let pathIDs = record.lineID.map { [$0] } ?? []
            return MapFeature(id: index, kind: .line, paths: paths, attributes: record.displayAttributes,
                stableIdentity: record.lineID ?? record.sourceFeatureIdentity,
                pathStableIdentities: pathIDs, hasUniqueStableIdentity: true,
                sourceFeatureIndex: index, geometryPath: "shape.parts",
                sourceCoordinatePaths: sourcePaths, sourceAttributes: sourceAttributes,
                sourceAttributeColumns: record.attributeColumns)
        }
    }

    private static func makeMapLayer(for draft: ShapefilePolylineDraft,
                                     scope: PolylineMapEditingScope,
                                     sourceRevision: String) -> MapVectorLayer {
        MapVectorLayer(url: draft.sourceLayer.url, features: mapFeatures(for: draft.records),
            sourceMapID: scope.mapID, sourceRevision: sourceRevision,
            visualIdentity: draft.sourceLayer.visualIdentity,
            visualName: draft.sourceLayer.visualName,
            isSourceVisible: draft.sourceLayer.isSourceVisible,
            sourceProjectionWKT: draft.sourceLayer.sourceProjectionWKT,
            targetProjectionWKT: draft.sourceLayer.targetProjectionWKT)
    }

    private static func emptyAttributes(for columns: [MapSourceAttributeColumn]) ->
        (display: [String: String], columns: [MapSourceAttributeColumn]) {
        let empty = columns.map { column -> MapSourceAttributeColumn in
            let value: MapSourceAttributeValue
            switch column.value {
            case .integer: value = .integer("0")
            case .number: value = .number("0")
            case .boolean: value = .boolean(false)
            default: value = .null
            }
            return MapSourceAttributeColumn(ordinal: column.ordinal, name: column.name, value: value)
        }
        var display: [String: String] = [:]
        for column in empty { display[column.name] = displayString(column.value) }
        return (display, empty)
    }

    private static func displayString(_ value: MapSourceAttributeValue) -> String {
        switch value {
        case .null: ""
        case .string(let value), .integer(let value), .number(let value), .date(let value): value
        case .boolean(let value): String(value)
        case .binary: ""
        }
    }

    private static func reindexedForDraft(_ records: [ShapefilePolylineDraftRecord]) -> [ShapefilePolylineDraftRecord] {
        records
    }

    private static func ordinateStrings(_ coordinates: [MapSourceCoordinate],
                                        keyPath: KeyPath<MapSourceCoordinate, Double?>) -> [String]? {
        guard !coordinates.isEmpty else { return nil }
        let values = coordinates.compactMap { $0[keyPath: keyPath] }
        guard values.count == coordinates.count, values.allSatisfy(\.isFinite) else { return nil }
        return values.map { String($0) }
    }

    private static func coordinatesWithDimensions(_ coordinates: [MapSourceCoordinate],
                                                   zValues: [String]?, mValues: [String]?) throws -> [MapSourceCoordinate] {
        guard zValues.map({ $0.count == coordinates.count }) ?? true,
              mValues.map({ $0.count == coordinates.count }) ?? true else {
            throw BackendServiceError(code: "protocolFailure", message: "The saved Shapefile reply has inconsistent Z/M dimensions.")
        }
        let z = try zValues.map(parseFiniteOrdinates)
        let m = try mValues.map(parseFiniteOrdinates)
        return coordinates.indices.map { index in
            MapSourceCoordinate(x: coordinates[index].x, y: coordinates[index].y,
                z: z.map { $0[index] }, m: m.map { $0[index] })
        }
    }

    private func shapefileSnapshot(_ draft: ShapefilePolylineDraft) -> ShapefilePolylineUndoSnapshot {
        ShapefilePolylineUndoSnapshot(records: draft.records, selectedLineID: selectedLineID,
            selectedLineIDs: selectedLineIDs, selectedVertexIndices: selectedVertexIndices,
            selectedVertexIndex: selectedVertexIndex, openedLineID: openedLineID)
    }

    private func restoreShapefileSelection(_ snapshot: ShapefilePolylineUndoSnapshot) {
        guard var draft = shapefileDraft else { return }
        draft.records = snapshot.records
        shapefileDraft = draft
        lines = Self.lines(from: snapshot.records, sourceName: draft.sourceLayer.name,
                           revision: currentSourceRevision ?? "")
        let validIDs = Set(lines.map(\.id))
        selectedLineIDs = snapshot.selectedLineIDs.intersection(validIDs)
        selectedLineID = snapshot.selectedLineID.flatMap { validIDs.contains($0) ? $0 : nil }
            ?? selectedLineIDs.first
        selectedVertexIndices = snapshot.selectedVertexIndices
        selectedVertexIndex = snapshot.selectedVertexIndex
        normalizeVertexSelection()
        openedLineID = snapshot.openedLineID.flatMap { validIDs.contains($0) ? $0 : nil }
    }

    private func normalizeVertexSelection() {
        guard let selectedLine else { clearVertexSelection(); return }
        selectedVertexIndices = Set(selectedVertexIndices.filter { selectedLine.points.indices.contains($0) })
        if let selectedVertexIndex, selectedVertexIndices.contains(selectedVertexIndex) {
            // Keep the current primary point while it remains selected.
        } else {
            selectedVertexIndex = selectedVertexIndices.sorted().first
        }
    }

    private func snapshot(document: GeoJSONPolylineDocument) -> PolylineUndoSnapshot {
        PolylineUndoSnapshot(document: document, selectedLineID: selectedLineID,
            selectedLineIDs: selectedLineIDs, selectedVertexIndices: selectedVertexIndices,
            selectedVertexIndex: selectedVertexIndex, openedLineID: openedLineID)
    }

    private func restore(_ snapshot: PolylineUndoSnapshot) {
        document = snapshot.document; lines = snapshot.document.lines
        selectedLineIDs = Set(snapshot.selectedLineIDs.filter { id in lines.contains(where: { $0.id == id }) })
        selectedLineID = snapshot.selectedLineID.flatMap { id in lines.contains(where: { $0.id == id }) ? id : nil }
        if selectedLineID == nil { selectedLineID = selectedLineIDs.sorted().first }
        openedLineID = snapshot.openedLineID.flatMap { id in lines.contains(where: { $0.id == id }) ? id : nil }
        selectedVertexIndices = snapshot.selectedVertexIndices
        selectedVertexIndex = snapshot.selectedVertexIndex
        normalizeVertexSelection()
    }

    private func pushUndo(_ document: GeoJSONPolylineDocument) {
        undoStack.append(snapshot(document: document))
        if undoStack.count > 100 { undoStack.removeFirst(undoStack.count - 100) }
    }
    private func removeLastUndoIfEqual(to document: GeoJSONPolylineDocument) {
        guard let last = undoStack.last, (try? last.document.encoded()) == (try? document.encoded()) else { return }
        undoStack.removeLast()
    }
    private func notifyChange() { didChange?() }

    private func showSharedEditGateError() {
        errorMessage = "Save or discard this layer's edits in the other map before editing it here."
        notifyChange()
    }
}
