import Combine
import Foundation
import RASWorkspaceCore
import SwiftUI

struct TerrainInputRenderedFeature: Identifiable, Sendable {
    let id: String
    let inputNodeID: String
    let inputIndex: Int
    let sourceClass: String
    let kind: String
    let points: [TerrainMapCoordinate]
    let closed: Bool
    let terrainPath: String
    let terrainRevision: String
}

/// Transient visibility for source TerrainInput vector contexts. The retained
/// application defaults these contexts to unchecked and does not serialize
/// their checkbox state into the map's .vis tree.
@MainActor
final class TerrainInputMapSession: ObservableObject {
    @Published private(set) var checkedNodeIDs: Set<String> = []
    @Published private(set) var features: [TerrainInputRenderedFeature] = []
    @Published private(set) var loadingNodeIDs: Set<String> = []
    @Published private(set) var errorsByNodeID: [String: String] = [:]

    private static let renderableSourceClasses: Set<String> = [
        "ChannelModTerrainInputParentVC",
        "LeveeModTerrainInputVC",
        "PolygonRasterModTerrainInputVisualContext"
    ]

    private var request: TerrainInputMapTreeRequest?
    private var projectSessionID: UUID?
    private var mapWorkflowIdentity: String?
    private var provider: (any TerrainInputMapContextProvider)?
    private var isCurrent: @MainActor () -> Bool = { false }
    private var canReadSource: @MainActor () -> Bool = { false }
    private var generation: UInt64 = 0
    private var nodeGenerations: [String: UInt64] = [:]
    private var requests: [String: Task<TerrainInputMapContextData, any Error>] = [:]

    var isConfigured: Bool { request != nil && projectSessionID != nil && mapWorkflowIdentity != nil }

    func configure(mapRequest: MapResultChartMapRequest?,
                   resultSelectionOverrides: [MapTreeResultSelectionOverride],
                   projectSessionID: UUID,
                   mapWorkflowIdentity: String,
                   provider: (any TerrainInputMapContextProvider)?,
                   isCurrent: @escaping @MainActor () -> Bool,
                   canReadSource: @escaping @MainActor () -> Bool) {
        let nextRequest = mapRequest.map {
            TerrainInputMapTreeRequest(map: $0, resultSelectionOverrides: resultSelectionOverrides)
        }
        if request == nextRequest, self.projectSessionID == projectSessionID,
           self.mapWorkflowIdentity == mapWorkflowIdentity {
            self.provider = provider
            self.isCurrent = isCurrent
            self.canReadSource = canReadSource
            return
        }
        invalidate()
        self.request = nextRequest
        self.projectSessionID = nextRequest == nil ? nil : projectSessionID
        self.mapWorkflowIdentity = nextRequest == nil ? nil : mapWorkflowIdentity
        self.provider = provider
        self.isCurrent = isCurrent
        self.canReadSource = canReadSource
    }

    func isChecked(_ nodeID: String) -> Bool { checkedNodeIDs.contains(nodeID) }

    func error(for nodeID: String) -> String? { errorsByNodeID[nodeID] }

    /// Stops source reads while a writer owns the terrain source. Already
    /// completed overlays remain visible because their captured geometry is
    /// immutable; a check that was still loading is retired and must be
    /// explicitly checked again after the writer releases the source.
    func suspendSourceReads() {
        generation &+= 1
        for task in requests.values { task.cancel() }
        requests.removeAll()
        for nodeID in loadingNodeIDs {
            nodeGenerations[nodeID, default: 0] &+= 1
            checkedNodeIDs.remove(nodeID)
            features.removeAll { $0.inputNodeID == nodeID }
            errorsByNodeID.removeValue(forKey: nodeID)
        }
        loadingNodeIDs.removeAll()
    }

    /// Applies a user checkbox change to one exact node from the current map
    /// tree. Each check re-resolves that node through MapTree and its parent
    /// HDF before source geometry is returned.
    func setChecked(nodeID: String, sourceClass: String, terrainPath: String,
                    isChecked: Bool) async {
        guard Self.renderableSourceClasses.contains(sourceClass),
              nodeID.hasPrefix("terrain-input:"), !terrainPath.isEmpty else {
            errorsByNodeID[nodeID] = L10n.text("This terrain input has no map render layer.")
            return
        }

        // Unchecking only retires local transient state. It must remain
        // available while a source read is gated, and it must cancel any
        // in-flight render before the stale reply can reinstall geometry.
        if !isChecked {
            nodeGenerations[nodeID, default: 0] &+= 1
            requests.removeValue(forKey: nodeID)?.cancel()
            checkedNodeIDs.remove(nodeID)
            loadingNodeIDs.remove(nodeID)
            errorsByNodeID.removeValue(forKey: nodeID)
            features.removeAll { $0.inputNodeID == nodeID }
            return
        }

        guard request != nil, let provider, isCurrent(), canReadSource() else {
            errorsByNodeID[nodeID] = L10n.text("The current map source is unavailable for this terrain input.")
            return
        }

        nodeGenerations[nodeID, default: 0] &+= 1
        let nodeGeneration = nodeGenerations[nodeID, default: 0]
        requests.removeValue(forKey: nodeID)?.cancel()

        checkedNodeIDs.insert(nodeID)
        loadingNodeIDs.insert(nodeID)
        errorsByNodeID.removeValue(forKey: nodeID)
        features.removeAll { $0.inputNodeID == nodeID }

        guard let map = request else { return }
        let capturedGeneration = generation
        let capturedProjectSessionID = projectSessionID
        let capturedWorkflowIdentity = mapWorkflowIdentity
        let contextRequest = TerrainInputMapContextRequest(map: map, inputNodeID: nodeID,
            expectedSourceClass: sourceClass,
            expectedTerrainPath: SourceFilePaths.canonical(URL(fileURLWithPath: terrainPath)))
        let task = Task { try await provider.renderTerrainInput(contextRequest) }
        requests[nodeID] = task
        do {
            let response = try await task.value
            guard !task.isCancelled, generation == capturedGeneration,
                  nodeGenerations[nodeID] == nodeGeneration, checkedNodeIDs.contains(nodeID),
                  self.projectSessionID == capturedProjectSessionID,
                  self.mapWorkflowIdentity == capturedWorkflowIdentity,
                  request == map else { return }
            guard isCurrent() else { invalidate(); return }
            guard canReadSource() else {
                checkedNodeIDs.remove(nodeID)
                loadingNodeIDs.remove(nodeID)
                requests.removeValue(forKey: nodeID)
                features.removeAll { $0.inputNodeID == nodeID }
                errorsByNodeID[nodeID] = L10n.text("The map source became unavailable while loading the terrain input.")
                return
            }
            let validated = try response.validated(for: contextRequest)
            features.append(contentsOf: validated)
            features.sort {
                $0.inputIndex == $1.inputIndex ? $0.id < $1.id : $0.inputIndex < $1.inputIndex
            }
            loadingNodeIDs.remove(nodeID)
            errorsByNodeID.removeValue(forKey: nodeID)
            requests.removeValue(forKey: nodeID)
        } catch {
            guard generation == capturedGeneration,
                  nodeGenerations[nodeID] == nodeGeneration,
                  checkedNodeIDs.contains(nodeID) else { return }
            loadingNodeIDs.remove(nodeID)
            requests.removeValue(forKey: nodeID)
            errorsByNodeID[nodeID] = L10n.text(error.localizedDescription)
        }
    }

    func invalidate() {
        generation &+= 1
        for task in requests.values { task.cancel() }
        requests.removeAll()
        nodeGenerations.removeAll()
        checkedNodeIDs.removeAll()
        features.removeAll()
        loadingNodeIDs.removeAll()
        errorsByNodeID.removeAll()
        request = nil
        projectSessionID = nil
        mapWorkflowIdentity = nil
        provider = nil
        isCurrent = { false }
        canReadSource = { false }
    }
}

/// Passive map overlay. Coordinates are already transformed by the source
/// service into the project's CRS and are mapped through the exact camera
/// shared by the raster/vector map canvases.
struct TerrainInputMapCanvas: View {
    let features: [TerrainInputRenderedFeature]
    let points: [MapPoint]
    let scale: CGFloat
    let offset: CGSize

    var body: some View {
        GeometryReader { proxy in
            let transform = MapTransform(points: points, size: proxy.size, scale: scale, offset: offset)
            Canvas { context, _ in
                for feature in features {
                    var path = Path()
                    guard let first = feature.points.first else { continue }
                    path.move(to: transform.screen(MapPoint(x: first.x, y: first.y)))
                    for point in feature.points.dropFirst() {
                        path.addLine(to: transform.screen(MapPoint(x: point.x, y: point.y)))
                    }
                    if feature.closed { path.closeSubpath() }
                    switch feature.sourceClass {
                    case "PolygonRasterModTerrainInputVisualContext":
                        context.stroke(path, with: .color(.black), lineWidth: 2)
                    default:
                        context.stroke(path, with: .color(.black), lineWidth: 1)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

@MainActor
struct TerrainInputVisibilityToggle: View {
    let node: LayerTreeNode
    let mapID: UUID
    let projectSessionID: UUID
    @ObservedObject var mapSession: TerrainInputMapSession
    let isCurrent: @MainActor () -> Bool
    let setVisibility: @MainActor (Bool) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Toggle("Visible", isOn: Binding(
                get: { mapSession.isChecked(node.id) },
                set: { checked in
                    guard isCurrent() else { return }
                    setVisibility(checked)
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!isCurrent())

            if mapSession.loadingNodeIDs.contains(node.id) {
                ProgressView().controlSize(.mini)
            }
            if let error = mapSession.error(for: node.id) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(error)
                    .accessibilityLabel(Text(error))
            }
        }
        .accessibilityIdentifier("terrain-input-visibility-\(node.id)")
        .id("\(projectSessionID)-\(mapID)-\(node.id)")
    }
}
