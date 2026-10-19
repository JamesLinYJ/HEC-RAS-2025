import Combine
import CoreGraphics
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

struct TerrainInputMapLeveeRenderState {
    let inputIndex: Int
    let data: TerrainInputMapLeveeRendererData
    let profileStationsImage: CGImage?
    let tinImage: CGImage?
}

struct TerrainInputMapRasterOverlay: Identifiable {
    enum Role: Equatable { case profileStations, tin }
    let id: String
    let inputNodeID: String
    let role: Role
    let frame: MapSourceRasterFrame
    let image: CGImage
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
    @Published private(set) var leveeRenderersByNodeID: [String: TerrainInputMapLeveeRenderState] = [:]
    @Published private(set) var renderRevision = 0
    @Published private(set) var contextRevision = 0

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
    private struct SourceCapture: Equatable {
        let sourceClass: String
        let terrainPath: String
    }
    private struct LeveeOptions: Equatable {
        var showProfileStations = false
        var showTin = false
        var debugMode = false
        var tinOptions = TerrainInputMapTinRenderOptions.sourceDefault
        var hasEnabledOption: Bool { showProfileStations || showTin }
    }
    private var checkedSourcesByNodeID: [String: SourceCapture] = [:]
    private var leveeOptionsByNodeID: [String: LeveeOptions] = [:]
    private var renderViewport: MapSourceRenderViewport?

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

    var hasRenderViewport: Bool { renderViewport != nil }

    func showsProfileStations(_ nodeID: String) -> Bool {
        leveeOptionsByNodeID[nodeID]?.showProfileStations ?? false
    }

    func showsTin(_ nodeID: String) -> Bool {
        leveeOptionsByNodeID[nodeID]?.showTin ?? false
    }

    func tinOptions(_ nodeID: String) -> TerrainInputMapTinRenderOptions {
        leveeOptionsByNodeID[nodeID]?.tinOptions ?? .sourceDefault
    }

    func leveeRendererWarning(_ nodeID: String) -> String? {
        leveeRenderersByNodeID[nodeID]?.data.tinWarning
    }

    var visibleRasterOverlays: [TerrainInputMapRasterOverlay] {
        leveeRenderersByNodeID.keys.sorted { lhs, rhs in
            let left = leveeRenderersByNodeID[lhs]?.inputIndex ?? Int.max
            let right = leveeRenderersByNodeID[rhs]?.inputIndex ?? Int.max
            return left == right ? lhs < rhs : left < right
        }.flatMap { nodeID -> [TerrainInputMapRasterOverlay] in
            guard checkedNodeIDs.contains(nodeID), let state = leveeRenderersByNodeID[nodeID] else { return [] }
            var result: [TerrainInputMapRasterOverlay] = []
            if let frame = state.data.profileStations, let image = state.profileStationsImage {
                result.append(TerrainInputMapRasterOverlay(id: "\(nodeID):profileStations",
                    inputNodeID: nodeID, role: .profileStations, frame: frame, image: image))
            }
            if let frame = state.data.tin, let image = state.tinImage {
                result.append(TerrainInputMapRasterOverlay(id: "\(nodeID):tin",
                    inputNodeID: nodeID, role: .tin, frame: frame, image: image))
            }
            return result
        }
    }

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
            checkedSourcesByNodeID.removeValue(forKey: nodeID)
            leveeOptionsByNodeID.removeValue(forKey: nodeID)
            leveeRenderersByNodeID.removeValue(forKey: nodeID)
            errorsByNodeID.removeValue(forKey: nodeID)
        }
        loadingNodeIDs.removeAll()
        renderRevision &+= 1
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
            checkedSourcesByNodeID.removeValue(forKey: nodeID)
            leveeOptionsByNodeID.removeValue(forKey: nodeID)
            leveeRenderersByNodeID.removeValue(forKey: nodeID)
            errorsByNodeID.removeValue(forKey: nodeID)
            features.removeAll { $0.inputNodeID == nodeID }
            renderRevision &+= 1
            return
        }

        guard request != nil, provider != nil, isCurrent(), canReadSource() else {
            errorsByNodeID[nodeID] = L10n.text("The current map source is unavailable for this terrain input.")
            return
        }

        checkedNodeIDs.insert(nodeID)
        checkedSourcesByNodeID[nodeID] = SourceCapture(sourceClass: sourceClass,
            terrainPath: SourceFilePaths.canonical(URL(fileURLWithPath: terrainPath)))
        if sourceClass == "LeveeModTerrainInputVC" { leveeOptionsByNodeID[nodeID] = LeveeOptions() }
        await loadCheckedNode(nodeID)
    }

    func setShowsProfileStations(_ enabled: Bool, nodeID: String) async {
        guard checkedNodeIDs.contains(nodeID),
              checkedSourcesByNodeID[nodeID]?.sourceClass == "LeveeModTerrainInputVC" else { return }
        var options = leveeOptionsByNodeID[nodeID] ?? LeveeOptions()
        guard options.showProfileStations != enabled else { return }
        options.showProfileStations = enabled
        leveeOptionsByNodeID[nodeID] = options
        await updateLeveeRenderer(nodeID)
    }

    func setShowsTin(_ enabled: Bool, nodeID: String, debugMode: Bool) async {
        guard checkedNodeIDs.contains(nodeID),
              checkedSourcesByNodeID[nodeID]?.sourceClass == "LeveeModTerrainInputVC" else { return }
        guard !enabled || debugMode else {
            errorsByNodeID[nodeID] = L10n.text("The Levee TIN map layer is available only in debug mode.")
            return
        }
        var options = leveeOptionsByNodeID[nodeID] ?? LeveeOptions()
        options.showTin = enabled
        options.debugMode = debugMode
        guard options != leveeOptionsByNodeID[nodeID] else { return }
        leveeOptionsByNodeID[nodeID] = options
        await updateLeveeRenderer(nodeID)
    }

    func setTinOptions(_ tinOptions: TerrainInputMapTinRenderOptions, nodeID: String) async {
        guard checkedNodeIDs.contains(nodeID),
              checkedSourcesByNodeID[nodeID]?.sourceClass == "LeveeModTerrainInputVC",
              !tinOptions.labelEdges, !tinOptions.labelPoints else { return }
        var options = leveeOptionsByNodeID[nodeID] ?? LeveeOptions()
        guard options.tinOptions != tinOptions else { return }
        options.tinOptions = tinOptions
        leveeOptionsByNodeID[nodeID] = options
        if options.showTin { await updateLeveeRenderer(nodeID) }
    }

    /// The map owns this live project-coordinate viewport. A changed camera
    /// retires old render jobs and asks the actual source renderer for fresh
    /// pixels only for enabled Levee options.
    func updateRenderViewport(_ viewport: MapSourceRenderViewport?) async {
        guard renderViewport != viewport else { return }
        renderViewport = viewport
        let nodeIDs = checkedNodeIDs.filter { leveeOptionsByNodeID[$0]?.hasEnabledOption == true }
        if viewport == nil {
            for nodeID in nodeIDs {
                nodeGenerations[nodeID, default: 0] &+= 1
                requests.removeValue(forKey: nodeID)?.cancel()
                loadingNodeIDs.remove(nodeID)
                leveeRenderersByNodeID.removeValue(forKey: nodeID)
                errorsByNodeID.removeValue(forKey: nodeID)
            }
            renderRevision &+= 1
            return
        }
        for nodeID in nodeIDs { await loadCheckedNode(nodeID) }
        renderRevision &+= 1
    }

    private func updateLeveeRenderer(_ nodeID: String) async {
        guard let options = leveeOptionsByNodeID[nodeID] else { return }
        guard options.hasEnabledOption else {
            nodeGenerations[nodeID, default: 0] &+= 1
            requests.removeValue(forKey: nodeID)?.cancel()
            loadingNodeIDs.remove(nodeID)
            leveeRenderersByNodeID.removeValue(forKey: nodeID)
            errorsByNodeID.removeValue(forKey: nodeID)
            renderRevision &+= 1
            return
        }
        guard renderViewport != nil else {
            leveeRenderersByNodeID.removeValue(forKey: nodeID)
            renderRevision &+= 1
            return
        }
        await loadCheckedNode(nodeID)
    }

    private func loadCheckedNode(_ nodeID: String) async {
        guard checkedNodeIDs.contains(nodeID), let source = checkedSourcesByNodeID[nodeID],
              let map = request, let provider, isCurrent(), canReadSource() else {
            errorsByNodeID[nodeID] = L10n.text("The current map source is unavailable for this terrain input.")
            leveeRenderersByNodeID.removeValue(forKey: nodeID)
            renderRevision &+= 1
            return
        }
        nodeGenerations[nodeID, default: 0] &+= 1
        let nodeGeneration = nodeGenerations[nodeID, default: 0]
        requests.removeValue(forKey: nodeID)?.cancel()
        loadingNodeIDs.insert(nodeID)
        errorsByNodeID.removeValue(forKey: nodeID)
        leveeRenderersByNodeID.removeValue(forKey: nodeID)
        let capturedGeneration = generation
        let capturedProjectSessionID = projectSessionID
        let capturedWorkflowIdentity = mapWorkflowIdentity
        let viewport = renderViewport
        let settings = leveeOptionsByNodeID[nodeID]
        let renderOptions: TerrainInputMapRenderOptions?
        if source.sourceClass == "LeveeModTerrainInputVC", let viewport,
           settings?.hasEnabledOption == true {
            renderOptions = TerrainInputMapRenderOptions(viewport: viewport.extent,
                showProfileStations: settings?.showProfileStations == true,
                showTin: settings?.showTin == true,
                debugMode: settings?.debugMode == true,
                renderScale: viewport.renderScale,
                tinOptions: settings?.showTin == true ? settings?.tinOptions : nil)
        } else {
            renderOptions = nil
        }
        let contextRequest = TerrainInputMapContextRequest(map: map, inputNodeID: nodeID,
            expectedSourceClass: source.sourceClass, expectedTerrainPath: source.terrainPath,
            renderOptions: renderOptions)
        let task = Task { try await provider.renderTerrainInput(contextRequest) }
        requests[nodeID] = task
        do {
            let response = try await task.value
            guard !task.isCancelled, generation == capturedGeneration,
                  nodeGenerations[nodeID] == nodeGeneration, checkedNodeIDs.contains(nodeID),
                  self.projectSessionID == capturedProjectSessionID,
                  self.mapWorkflowIdentity == capturedWorkflowIdentity,
                  request == map, renderViewport == viewport,
                  checkedSourcesByNodeID[nodeID] == source else { return }
            guard isCurrent() else { invalidate(); return }
            guard canReadSource() else {
                checkedNodeIDs.remove(nodeID)
                loadingNodeIDs.remove(nodeID)
                requests.removeValue(forKey: nodeID)
                checkedSourcesByNodeID.removeValue(forKey: nodeID)
                leveeOptionsByNodeID.removeValue(forKey: nodeID)
                features.removeAll { $0.inputNodeID == nodeID }
                leveeRenderersByNodeID.removeValue(forKey: nodeID)
                errorsByNodeID[nodeID] = L10n.text("The map source became unavailable while loading the terrain input.")
                renderRevision &+= 1
                return
            }
            let validatedFeatures = try response.validated(for: contextRequest)
            let rendererData = try response.validatedLeveeRenderer(for: contextRequest)
            features.removeAll { $0.inputNodeID == nodeID }
            features.append(contentsOf: validatedFeatures)
            features.sort {
                $0.inputIndex == $1.inputIndex ? $0.id < $1.id : $0.inputIndex < $1.inputIndex
            }
            if let rendererData {
                let profileImage = rendererData.profileStations?.image
                let tinImage = rendererData.tin?.image
                guard (rendererData.profileStations == nil || profileImage != nil),
                      (rendererData.tin == nil || tinImage != nil) else {
                    throw BackendServiceError(code: "protocolFailure",
                        message: L10n.text("The terrain input renderer returned invalid image data."))
                }
                leveeRenderersByNodeID[nodeID] = TerrainInputMapLeveeRenderState(
                    inputIndex: response.inputIndex, data: rendererData,
                    profileStationsImage: profileImage, tinImage: tinImage)
            } else {
                leveeRenderersByNodeID.removeValue(forKey: nodeID)
            }
            loadingNodeIDs.remove(nodeID)
            errorsByNodeID.removeValue(forKey: nodeID)
            requests.removeValue(forKey: nodeID)
            renderRevision &+= 1
        } catch {
            guard generation == capturedGeneration,
                  nodeGenerations[nodeID] == nodeGeneration,
                  checkedNodeIDs.contains(nodeID) else { return }
            loadingNodeIDs.remove(nodeID)
            requests.removeValue(forKey: nodeID)
            features.removeAll { $0.inputNodeID == nodeID }
            leveeRenderersByNodeID.removeValue(forKey: nodeID)
            errorsByNodeID[nodeID] = L10n.text(error.localizedDescription)
            renderRevision &+= 1
        }
    }

    func invalidate() {
        generation &+= 1
        contextRevision &+= 1
        for task in requests.values { task.cancel() }
        requests.removeAll()
        nodeGenerations.removeAll()
        checkedNodeIDs.removeAll()
        features.removeAll()
        leveeRenderersByNodeID.removeAll()
        loadingNodeIDs.removeAll()
        errorsByNodeID.removeAll()
        checkedSourcesByNodeID.removeAll()
        leveeOptionsByNodeID.removeAll()
        renderViewport = nil
        request = nil
        projectSessionID = nil
        mapWorkflowIdentity = nil
        provider = nil
        isCurrent = { false }
        canReadSource = { false }
        renderRevision &+= 1
    }
}

/// Passive map overlay. Coordinates are already transformed by the source
/// service into the project's CRS and are mapped through the exact camera
/// shared by the raster/vector map canvases.
struct TerrainInputMapCanvas: View {
    @ObservedObject private var renderScaling = WorkspaceRenderScaling.shared
    @ObservedObject var session: TerrainInputMapSession
    let features: [TerrainInputRenderedFeature]
    let points: [MapPoint]
    let scale: CGFloat
    let offset: CGSize

    var body: some View {
        GeometryReader { proxy in
            let viewport = MapSourceRenderViewport.capture(points: points, size: proxy.size,
                scale: scale, offset: offset, deviceRenderScale: renderScaling.factor)
            let transform = MapTransform(points: points, size: proxy.size, scale: scale, offset: offset)
            let overlays = session.visibleRasterOverlays
            Canvas { context, _ in
                let groups = Dictionary(grouping: features, by: \.inputNodeID)
                let orderedIDs = groups.keys.sorted { lhs, rhs in
                    let left = groups[lhs]?.first?.inputIndex ?? Int.max
                    let right = groups[rhs]?.first?.inputIndex ?? Int.max
                    return left == right ? lhs < rhs : left < right
                }
                for nodeID in orderedIDs {
                    for feature in groups[nodeID] ?? [] {
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
                    for overlay in overlays where overlay.inputNodeID == nodeID && overlay.role == .profileStations {
                        Self.draw(overlay, in: &context, transform: transform)
                    }
                }
                for overlay in overlays where overlay.role == .tin {
                    Self.draw(overlay, in: &context, transform: transform)
                }
            }
            .task(id: "\(viewport?.identity ?? "unavailable"):\(session.contextRevision)") {
                await session.updateRenderViewport(viewport)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func draw(_ overlay: TerrainInputMapRasterOverlay,
                             in context: inout GraphicsContext, transform: MapTransform) {
        let frame = overlay.frame
        let upperLeft = transform.screen(MapPoint(x: frame.minX, y: frame.maxY))
        let lowerRight = transform.screen(MapPoint(x: frame.maxX, y: frame.minY))
        let rect = CGRect(x: min(upperLeft.x, lowerRight.x), y: min(upperLeft.y, lowerRight.y),
            width: abs(lowerRight.x - upperLeft.x), height: abs(lowerRight.y - upperLeft.y))
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return }
        context.draw(Image(decorative: overlay.image, scale: 1), in: rect)
        for label in frame.labels {
            let text = context.resolve(Text(verbatim: label.text).font(.caption2))
            context.draw(text, at: transform.screen(MapPoint(x: label.x, y: label.y)), anchor: .bottomLeading)
        }
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
