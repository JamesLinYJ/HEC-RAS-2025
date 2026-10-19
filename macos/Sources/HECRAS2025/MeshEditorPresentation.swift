import Foundation
import RASWorkspaceCore

enum GeometryMeshBindings {
    // Source FlowAreaInformation follows the FlowAreaLayerVisualContext link.
    static let flowArea = "GeometryMeshPage/FlowArea"
    static let regions = "Regions"
}
struct MeshMetadataValue: Identifiable, Sendable {
    let id: String
    let title: String
    let value: String
    var titleIsUserData = false
}
struct MeshNodeDegreeIssue: Identifiable, Sendable {
    let id: String
    let nodeIndex: Int
    let faceCount: Int
    var cellsExtent: ViewportRequest? = nil
    var nodePoint: MapPoint? = nil
    var viewport: ViewportRequest? {
        if let extent = cellsExtent {
            let x = extent.lowerLeft.x / 2 + extent.upperRight.x / 2
            let y = extent.lowerLeft.y / 2 + extent.upperRight.y / 2
            // Original CellsExtent.RatioAroundCenter(2.0).
            let dx = extent.upperRight.x - extent.lowerLeft.x
            let dy = extent.upperRight.y - extent.lowerLeft.y
            let result = ViewportRequest(lowerLeft: .init(x: x - dx, y: y - dy), upperRight: .init(x: x + dx, y: y + dy))
            if Self.valid(result) { return result }
        }
        if let point = nodePoint, point.x.isFinite, point.y.isFinite { return .init(lowerLeft: point, upperRight: point) }
        return nil
    }
    static func valid(_ extent: ViewportRequest) -> Bool {
        extent.isFiniteAndOrdered
    }
}
struct FlowAreaPresentation: Sendable {
    var cellCount: Int? = nil
    var metadata: [MeshMetadataValue] = []
    var degreeIssues: [MeshNodeDegreeIssue]? = nil // nil is unavailable; [] is an actual empty source list.
    func validate() throws {
        let issues = degreeIssues ?? []
        guard cellCount.map({ $0 >= 0 }) ?? true,
              Set(metadata.map(\.id)).count == metadata.count,
              Set(issues.map(\.id)).count == issues.count,
              issues.allSatisfy({ !$0.id.isEmpty && $0.faceCount >= 0 && ($0.cellsExtent.map(MeshNodeDegreeIssue.valid) ?? true) }) else {
            throw ProjectFileError.invalid("The source mesh summary contains invalid identities or counts.")
        }
    }
}
enum PatchEditorState: String, Sendable { case unavailable, loading, mixedTypes, ready }
enum MeshPatchKind: String, Sendable { case triangle = "Triangle", cartesian = "Cartesian", quad = "Quad", empty = "Empty" }
struct PatchDimensionPresentation: Identifiable, Sendable {
    let id: String
    let title: String
    let scope: String
    var canApply = false
    var canChangeMode = false
    var canResize = false
    var modeFieldID: String { scope + "/QuadPatchQuickEditorDimensionEditor/SizeFunction" }
    var valueFieldID: String { scope + "/QuadPatchQuickEditorDimensionEditor/LiveValue" }
    var mismatchFieldID: String { scope + "/QuadPatchQuickEditorDimensionEditor/HasMismatch" }
}
struct PatchEditorPresentation: Sendable {
    var state: PatchEditorState = .unavailable
    var kind: MeshPatchKind? = nil
    var dimensions: [PatchDimensionPresentation] = []
    var canResizeAll = false
    var editableFieldIDs: Set<String> = []
    var displayFieldIDs: Set<String> = []
    var message = ""
    func validate(scope: String) throws {
        guard !scope.isEmpty, Set(dimensions.map(\.id)).count == dimensions.count,
              state != .ready || kind != nil,
              Set(dimensions.map(\.scope)).count == dimensions.count,
              dimensions.allSatisfy({ !$0.id.isEmpty && $0.scope.hasPrefix(scope + "/") }),
              editableFieldIDs.isDisjoint(with: displayFieldIDs) else {
            throw ProjectFileError.invalid("The source patch editor contains invalid scopes or field identities.")
        }
    }
    func permits(_ operation: PatchEditOperation) -> Bool {
        guard state == .ready else { return false }
        switch operation {
        case .resizeAll(let ratio): return canResizeAll && [0.5, 2].contains(ratio)
        case .resizeDimension(let id, let ratio): return dimensions.contains { $0.id == id && $0.canResize } && [0.5, 2].contains(ratio)
        case .applyDimension(let id, let value): return dimensions.contains { $0.id == id && $0.canApply } && Double(value).map(\.isFinite) == true
        case .setDimensionMode(let id, let mode):
            let choices = SourceEditorLibrary.shared.schema("QuadPatchQuickEditorDimensionEditor")?.fields.first { $0.id == "SizeFunction" }?.choices ?? []
            return dimensions.contains { $0.id == id && $0.canChangeMode } && choices.contains { $0.id == mode }
        }
    }
}
enum PatchEditOperation: Sendable {
    case resizeAll(Double)
    case resizeDimension(id: String, ratio: Double)
    case applyDimension(id: String, value: String)
    case setDimensionMode(id: String, mode: String)
}
struct PatchEditRequest: Sendable {
    let scope: String
    let operation: PatchEditOperation
    let edits: EditorEdits
}
struct PatchEditResult: Sendable {
    let changed: Bool
    var fields: [String: String] = [:]
    var displayFields: [String: String] = [:]
}
