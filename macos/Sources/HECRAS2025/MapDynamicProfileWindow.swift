import Foundation
import RASWorkspaceCore
import SwiftUI

enum MapDynamicProfileWindowMode: Equatable, Sendable {
    case terrain
    case results
    case geometryDraft

    var plotsTerrain: Bool { true }
    var plotsResults: Bool { self != .terrain }
    var terrainRequiresElevationResult: Bool { self != .terrain }
    var showsResultMapTypeSelector: Bool { self != .terrain }
}

struct MapDynamicProfileWindowPresentation: Equatable, Sendable {
    let title: String
    let mode: MapDynamicProfileWindowMode
    let initialMapType: String?
    let targetSampleCount: Int
    /// Optional caller-supplied axis label units. Saved-map windows leave this
    /// nil and use the backend's authoritative project-unit response.
    let axisUnits: String?
    let showsResultMapTypeSelector: Bool
    let legendWidthThreshold: Double
    let legendHeightThreshold: Double
    let plotTerrains: Bool
    let terrainRequiresElevationResult: Bool

    init(title: String, mode: MapDynamicProfileWindowMode, axisUnits: String? = nil,
         showResultMapTypeSelector: Bool? = nil,
         legendWidthThreshold: Double? = nil, legendHeightThreshold: Double? = nil,
         plotTerrains: Bool? = nil, terrainRequiresElevationResult: Bool? = nil) {
        self.title = title
        self.mode = mode
        self.plotTerrains = plotTerrains ?? mode.plotsTerrain
        self.terrainRequiresElevationResult = terrainRequiresElevationResult
            ?? mode.terrainRequiresElevationResult
        // The original Terrain action starts on Water Surface Elevation even
        // though its result-map selector is hidden. The Results action exposes
        // that selector and starts at the same map type.
        // DynamicProfilePlot begins with Unknown, then selects the first
        // available option after its result-map options load. That first
        // option is WSE for the original embedded Geometry plot too. Source
        // Profile remains available as an explicit selector choice.
        initialMapType = "WaterSurfaceElevation"
        targetSampleCount = 256
        self.axisUnits = axisUnits
        showsResultMapTypeSelector = showResultMapTypeSelector ?? mode.showsResultMapTypeSelector
        // The original standalone-window overload passes zero thresholds;
        // the embedded Geometry plot uses the ChartView defaults (400 × 300).
        self.legendWidthThreshold = legendWidthThreshold
            ?? (mode == .geometryDraft ? 400 : 0)
        self.legendHeightThreshold = legendHeightThreshold
            ?? (mode == .geometryDraft ? 300 : 0)
    }

    var plotResults: Bool { mode.plotsResults }

    /// TopologyVisualContextBehaviors.CutArcProfileInternal uses different
    /// caller flags from PolylineLayerBehaviors: the selector stays visible,
    /// and Results plots omit terrain rather than applying elevation gating.
    static func topologyArcs(title: String, mode: MapDynamicProfileWindowMode)
        -> MapDynamicProfileWindowPresentation {
        .init(title: title, mode: mode, showResultMapTypeSelector: true,
              plotTerrains: mode != .results, terrainRequiresElevationResult: false)
    }

    static let geometryDraft = MapDynamicProfileWindowPresentation(
        title: "Dynamic Profile", mode: .geometryDraft)
}

@MainActor
final class MapDynamicProfileWindowSession: ObservableObject, Identifiable {
    private struct SourceBinding {
        let context: MapResultChartContext
        let sources: MapResultSourcesSnapshot
        let sourceWorkflowIdentity: String
        let mapWorkflowIdentity: String
        let line: MapDynamicProfileLine
        let linesToken: String
    }

    let id = UUID()
    let mapID: UUID
    let projectSessionID: UUID
    let editingSelection: Bool
    let presentation: MapDynamicProfileWindowPresentation
    let sampler: MapDynamicProfileSession
    let overlayOwner = UUID()

    @Published private(set) var isValid = true
    @Published private(set) var invalidReason: String?
    @Published private(set) var isRebindingSources = false
    @Published private var sourceBinding: SourceBinding
    weak var mapState: MapState?
    private var sourceRebindGeneration = 0
    private var sourceRebindTask: Task<Void, Never>?

    var context: MapResultChartContext { sourceBinding.context }
    var sources: MapResultSourcesSnapshot { sourceBinding.sources }
    var sourceWorkflowIdentity: String { sourceBinding.sourceWorkflowIdentity }
    var mapWorkflowIdentity: String { sourceBinding.mapWorkflowIdentity }
    var line: MapDynamicProfileLine { sourceBinding.line }
    var linesToken: String { sourceBinding.linesToken }

    init(mapState: MapState, projectSessionID: UUID, context: MapResultChartContext,
         sources: MapResultSourcesSnapshot, sourceWorkflowIdentity: String,
         mapWorkflowIdentity: String, editingSelection: Bool,
         presentation: MapDynamicProfileWindowPresentation,
         sampler: MapDynamicProfileSession) {
        self.mapState = mapState
        mapID = context.mapID
        self.projectSessionID = projectSessionID
        self.editingSelection = editingSelection
        self.presentation = presentation
        self.sampler = sampler
        let line = MapDynamicProfileLine(id: context.stableFeatureIdentity, points: context.sampleLine,
            feature: MapResultFeatureIdentity(vectorPath: context.vectorPath,
                vectorRevision: context.vectorRevision, featureID: context.stableFeatureIdentity,
                coordinateSHA: context.coordinateSHA))
        sourceBinding = SourceBinding(context: context, sources: sources,
            sourceWorkflowIdentity: sourceWorkflowIdentity,
            mapWorkflowIdentity: mapWorkflowIdentity, line: line,
            linesToken: GeometryDynamicProfileLines.token(lines: [line], sourceIdentity: context.identity))
    }

    @discardableResult
    func beginSourceRebind() -> Int {
        guard isValid else { return sourceRebindGeneration }
        sourceRebindGeneration &+= 1
        sourceRebindTask?.cancel()
        sourceRebindTask = nil
        isRebindingSources = true
        sampler.invalidate()
        mapState?.dynamicProfileOverlay.clear(owner: overlayOwner)
        return sourceRebindGeneration
    }

    func installSourceRebindTask(_ task: Task<Void, Never>, generation: Int) {
        guard isValid, isRebindingSources, generation == sourceRebindGeneration else {
            task.cancel()
            return
        }
        sourceRebindTask?.cancel()
        sourceRebindTask = task
    }

    func isCurrentSourceRebind(_ generation: Int) -> Bool {
        isValid && isRebindingSources && generation == sourceRebindGeneration
    }

    @discardableResult
    func rebindSourceContext(projectSessionID: UUID, mapID: UUID,
                             context: MapResultChartContext,
                             sources: MapResultSourcesSnapshot,
                             sourceWorkflowIdentity: String,
                             mapWorkflowIdentity: String) -> Bool {
        guard isValid else { return false }
        guard self.projectSessionID == projectSessionID, self.mapID == mapID,
              matchesStableMapLine(projectSessionID: projectSessionID, mapID: mapID,
                  context: context, editingSelection: editingSelection) else {
            invalidate(reason: L10n.text("The selected map, result source, or polyline changed."))
            return false
        }
        guard sources.map == context.mapRequest, sources.identity == mapWorkflowIdentity,
              !sourceWorkflowIdentity.isEmpty else {
            invalidate(reason: L10n.text("The selected map, result source, or polyline changed."))
            return false
        }
        let line = MapDynamicProfileLine(id: context.stableFeatureIdentity,
            points: context.sampleLine,
            feature: MapResultFeatureIdentity(vectorPath: context.vectorPath,
                vectorRevision: context.vectorRevision, featureID: context.stableFeatureIdentity,
                coordinateSHA: context.coordinateSHA))
        sourceBinding = SourceBinding(context: context, sources: sources,
            sourceWorkflowIdentity: sourceWorkflowIdentity,
            mapWorkflowIdentity: mapWorkflowIdentity, line: line,
            linesToken: GeometryDynamicProfileLines.token(lines: [line], sourceIdentity: context.identity))
        sourceRebindTask?.cancel()
        sourceRebindTask = nil
        isRebindingSources = false
        return true
    }

    func invalidate(reason: String? = nil) {
        guard isValid else { return }
        isValid = false
        invalidReason = reason
        isRebindingSources = false
        sourceRebindGeneration &+= 1
        sourceRebindTask?.cancel()
        sourceRebindTask = nil
        sampler.invalidate()
        mapState?.dynamicProfileOverlay.clear(owner: overlayOwner)
    }

    func matches(projectSessionID: UUID, mapID: UUID, context: MapResultChartContext,
                 mode: MapDynamicProfileWindowMode, editingSelection: Bool) -> Bool {
        isValid && self.projectSessionID == projectSessionID && self.mapID == mapID
            && matchesStableMapLine(projectSessionID: projectSessionID, mapID: mapID,
                context: context, editingSelection: editingSelection)
            && presentation.mode == mode
            && self.editingSelection == editingSelection
    }

    func matchesStableMapLine(projectSessionID: UUID, mapID: UUID,
                              context: MapResultChartContext,
                              editingSelection: Bool) -> Bool {
        guard self.projectSessionID == projectSessionID,
              self.mapID == mapID, context.projectSessionID == projectSessionID,
              context.mapID == mapID, self.editingSelection == editingSelection else { return false }
        let old = self.context
        let current = context
        return SourceFilePaths.canonical(URL(fileURLWithPath: old.projectPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: current.projectPath))
            && SourceFilePaths.canonical(URL(fileURLWithPath: old.vectorPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: current.vectorPath))
            && old.vectorRevision == current.vectorRevision
            && old.stableFeatureIdentity == current.stableFeatureIdentity
            && old.sampleLine == current.sampleLine
            && old.coordinateSHA == current.coordinateSHA
            && old.draftGeneration == current.draftGeneration
    }

    func close() { invalidate() }
}

struct MapDynamicProfileWindow: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var session: MapDynamicProfileWindowSession

    var body: some View {
        Group {
            if session.isValid,
               let state = store.existingMapState(for: session.mapID),
               let client = store.dynamicProfileBackendClient,
               store.isCurrentMapDynamicProfileWindow(session, state: state) {
                MapDynamicProfileWorkspace(store: store, mapState: state,
                    client: client,
                    lines: [session.line], linesToken: session.linesToken,
                    presentation: session.presentation, windowSession: session)
                    .navigationTitle(session.presentation.title)
            } else {
                ContentUnavailableView(L10n.text("Profile Plot Closed"),
                    systemImage: "chart.xyaxis.line",
                    description: Text(L10n.text(session.invalidReason
                        ?? "The selected map, result source, or polyline changed.")))
                    .navigationTitle(session.presentation.title)
            }
        }
        .onDisappear { store.unregisterMapDynamicProfileWindow(session.id) }
        .frame(minWidth: 760, minHeight: 520)
    }
}
