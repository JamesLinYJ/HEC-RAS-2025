import Foundation
import RASWorkspaceCore
import SwiftUI

/// The source DataGrid attaches TopologyVisualContext feature actions to the
/// selected FeatureContext row. This capture keeps the native action attached
/// to the same saved map, geometry owner, topology draft, and active result
/// source snapshot while the menu action is prepared or a profile is open.
struct GeometryTopologyFeatureActionCapture: Identifiable {
    let id = UUID()
    let projectSessionID: UUID
    let mapID: UUID
    let mapWorkflowIdentity: String
    let mapSourceWorkflowIdentity: String
    let geometry: ProjectGeometryMapCapture
    let geometryRevision: String
    let topologyDraftState: String
    let topologyAssetID: String
    let mapState: MapState
    let sources: MapResultSourcesSnapshot
    let arcRowIDs: Set<String>
    let lines: [MapDynamicProfileLine]
    let linesToken: String
    let mode: MapDynamicProfileWindowMode
    let presentation: MapDynamicProfileWindowPresentation
}

struct GeometryTopologyFeatureMapTarget {
    let projectSessionID: UUID
    let mapID: UUID
    let mapWorkflowIdentity: String
    let geometry: ProjectGeometryMapCapture
    let geometryRevision: String
    let topologyDraftState: String
    let topologyAssetID: String
    let mapState: MapState
    let sources: MapResultSourcesSnapshot
    let feature: GeometryTopologyMapFeature
    let selectionFeature: GeometryTopologyMapFeature
    let row: GeometryTopologyFeatureRow
    let viewport: ViewportRequest
}

@MainActor
enum GeometryTopologyFeatureActions {
    static func prepareMapTarget(store: WorkspaceStore, topology: GeometryTopologySession,
                                 featureKind: String, rowID: String) async -> GeometryTopologyFeatureMapTarget? {
        guard let initial = await prepareMapOwner(store: store, topology: topology),
              let snapshot = topology.snapshot,
              let row = topology.table(for: featureKind).rows.first(where: { $0.id == rowID }),
              let feature = draftFeature(snapshot: snapshot, featureKind: featureKind, row: row),
              let selectionFeature = mapFeature(snapshot: snapshot, featureKind: featureKind, row: row),
              let viewport = zoomExtent(feature: feature, kind: featureKind,
                  currentViewport: initial.mapState.currentExtent, topologyExtent: snapshot.map?.extent) else {
            return nil
        }
        guard mapOwnerIsCurrent(initial, store: store, topology: topology) else { return nil }
        return GeometryTopologyFeatureMapTarget(projectSessionID: initial.projectSessionID,
            mapID: initial.mapID, mapWorkflowIdentity: initial.mapWorkflowIdentity,
            geometry: initial.geometry, geometryRevision: initial.geometryRevision,
            topologyDraftState: initial.topologyDraftState, topologyAssetID: initial.topologyAssetID,
            mapState: initial.mapState, sources: initial.sources, feature: feature, selectionFeature: selectionFeature,
            row: row, viewport: viewport)
    }

    static func prepareProfile(store: WorkspaceStore, topology: GeometryTopologySession,
                               rowIDs: [String], mode: MapDynamicProfileWindowMode) async
        -> GeometryTopologyFeatureActionCapture? {
        guard !rowIDs.isEmpty,
              let initial = await prepareMapOwner(store: store, topology: topology),
              let snapshot = topology.snapshot else { return nil }
        let orderedRows = rowIDs.compactMap { id in
            topology.table(for: "arc").rows.first(where: { $0.id == id })
        }
        guard orderedRows.count == rowIDs.count,
              Set(orderedRows.map(\.id)).count == rowIDs.count,
              let lines = exactArcLines(snapshot: snapshot, rows: orderedRows),
              mapOwnerIsCurrent(initial, store: store, topology: topology) else { return nil }
        if mode == .results && initial.sources.sources.activeNodes.isEmpty { return nil }
        let token = GeometryDynamicProfileLines.token(lines: lines,
            sourceIdentity: initial.geometry.identity + "|" + initial.topologyDraftState)
        let title = L10n.format("%@ Profile Plot", initial.geometry.geometryName)
        return GeometryTopologyFeatureActionCapture(projectSessionID: initial.projectSessionID,
            mapID: initial.mapID, mapWorkflowIdentity: initial.mapWorkflowIdentity,
            mapSourceWorkflowIdentity: initial.mapSourceWorkflowIdentity,
            geometry: initial.geometry, geometryRevision: initial.geometryRevision,
            topologyDraftState: initial.topologyDraftState, topologyAssetID: initial.topologyAssetID,
            mapState: initial.mapState, sources: initial.sources, arcRowIDs: Set(orderedRows.map(\.id)), lines: lines,
            linesToken: token, mode: mode,
            presentation: .topologyArcs(title: title, mode: mode))
    }

    static func isCurrent(_ capture: GeometryTopologyFeatureActionCapture,
                          store: WorkspaceStore, topology: GeometryTopologySession) -> Bool {
        guard let current = currentMapOwner(store: store, topology: topology) else { return false }
        return current.projectSessionID == capture.projectSessionID
            && current.mapID == capture.mapID
            && current.mapWorkflowIdentity == capture.mapWorkflowIdentity
            && current.mapSourceWorkflowIdentity == capture.mapSourceWorkflowIdentity
            && current.geometry == capture.geometry
            && current.geometryRevision == capture.geometryRevision
            && current.topologyDraftState == capture.topologyDraftState
            && current.topologyAssetID == capture.topologyAssetID
            && current.mapState === capture.mapState
            && current.sources == capture.sources
    }

    static func zoom(_ target: GeometryTopologyFeatureMapTarget, store: WorkspaceStore,
                     topology: GeometryTopologySession) -> Bool {
        let initial = MapOwner(projectSessionID: target.projectSessionID, mapID: target.mapID,
            mapWorkflowIdentity: target.mapWorkflowIdentity,
            mapSourceWorkflowIdentity: store.mapSourceWorkflowIdentity(target.mapID),
            geometry: target.geometry, geometryRevision: target.geometryRevision,
            topologyDraftState: target.topologyDraftState, topologyAssetID: target.topologyAssetID,
            mapState: target.mapState, sources: target.sources)
        guard mapOwnerIsCurrent(initial, store: store, topology: topology) else { return false }
        guard let mapDocument = store.mapDocument(for: target.mapID) else { return false }
        store.openMapDocument(mapDocument)
        target.mapState.projectGeometryMap.select(ProjectGeometryMapSelection(
            id: target.geometry.identity + "|topology|" + target.selectionFeature.id,
            geometryName: target.geometry.geometryName,
            layerTitle: "Topology", featureLabel: "FID \(target.row.fid)"))
        target.mapState.viewport = target.viewport
        return true
    }

    static func currentProfileCaptureIsValid(_ capture: GeometryTopologyFeatureActionCapture,
                                             store: WorkspaceStore,
                                             topology: GeometryTopologySession) -> Bool {
        guard isCurrent(capture, store: store, topology: topology),
              let snapshot = topology.snapshot,
              snapshot.map != nil,
              let rows = selectedArcRows(topology: topology, rowIDs: capture.arcRowIDs),
              let lines = exactArcLines(snapshot: snapshot, rows: rows),
              lines == capture.lines,
              GeometryDynamicProfileLines.token(lines: capture.lines,
                  sourceIdentity: capture.geometry.identity + "|" + capture.topologyDraftState) == capture.linesToken
        else { return false }
        return capture.mode != .results || !capture.sources.sources.activeNodes.isEmpty
    }

    private struct MapOwner {
        let projectSessionID: UUID
        let mapID: UUID
        let mapWorkflowIdentity: String
        let mapSourceWorkflowIdentity: String
        let geometry: ProjectGeometryMapCapture
        let geometryRevision: String
        let topologyDraftState: String
        let topologyAssetID: String
        let mapState: MapState
        let sources: MapResultSourcesSnapshot
    }

    private static func prepareMapOwner(store: WorkspaceStore,
                                        topology: GeometryTopologySession) async -> MapOwner? {
        guard let assetID = topology.mapAssetIdentity,
              let topologySnapshot = topology.snapshot,
              let topologyRevision = topologySnapshot.revision.nilIfEmpty,
              store.mapResultRequest(for: store.lastActiveMapID) != nil else { return nil }
        let project = store.projectSessionID
        let mapID = store.lastActiveMapID
        let mapWorkflow = store.mapWorkflowIdentity(mapID)
        let mapState = store.existingMapState(for: mapID) ?? store.mapState(for: mapID)
        guard store.isCurrentMapState(mapState, mapID: mapID, projectSessionID: project) else { return nil }

        await store.configureMapResultSources(mapID)
        guard !Task.isCancelled, store.projectSessionID == project,
              store.lastActiveMapID == mapID,
              store.mapWorkflowIdentity(mapID) == mapWorkflow,
              topology.mapAssetIdentity == assetID,
              topology.snapshot?.revision == topologyRevision,
              topology.snapshot?.draftState == topologySnapshot.draftState,
              store.existingMapState(for: mapID) === mapState else { return nil }

        await store.configureProjectGeometryMap(mapID)
        guard !Task.isCancelled, store.projectSessionID == project,
              store.lastActiveMapID == mapID,
              store.mapWorkflowIdentity(mapID) == mapWorkflow,
              topology.mapAssetIdentity == assetID,
              topology.snapshot?.revision == topologyRevision,
              topology.snapshot?.draftState == topologySnapshot.draftState,
              store.existingMapState(for: mapID) === mapState,
              let sources = mapState.resultSources.snapshot,
              sources.map == store.mapResultRequest(for: mapID),
              sources.identity == mapWorkflow else { return nil }

        let canonicalAsset = SourceFilePaths.canonical(URL(fileURLWithPath: assetID))
        let sourceWorkflow = store.mapSourceWorkflowIdentity(mapID)
        let matches = mapState.projectGeometryMap.sources.filter { source in
            source.capture.projectSessionID == project
                && source.capture.mapID == mapID
                && source.capture.mapWorkflowIdentity == mapWorkflow
                && source.capture.geometryCanonicalPath == canonicalAsset
                && source.capture.geometryNode.nodeType == "Geometry"
        }
        guard matches.count == 1, let source = matches.first else { return nil }
        if let sourceRevision = source.snapshot?.geometryRevision, sourceRevision != topologyRevision {
            return nil
        }
        return MapOwner(projectSessionID: project, mapID: mapID,
            mapWorkflowIdentity: mapWorkflow, mapSourceWorkflowIdentity: sourceWorkflow,
            geometry: source.capture, geometryRevision: topologyRevision,
            topologyDraftState: topologySnapshot.draftState, topologyAssetID: assetID,
            mapState: mapState, sources: sources)
    }

    private static func currentMapOwner(store: WorkspaceStore,
                                       topology: GeometryTopologySession) -> MapOwner? {
        guard let assetID = topology.mapAssetIdentity,
              let topologySnapshot = topology.snapshot,
              let revision = topologySnapshot.revision.nilIfEmpty,
              let mapState = store.existingMapState(for: store.lastActiveMapID),
              let sources = mapState.resultSources.snapshot else { return nil }
        let project = store.projectSessionID
        let mapID = store.lastActiveMapID
        let mapWorkflow = store.mapWorkflowIdentity(mapID)
        guard store.isCurrentMapState(mapState, mapID: mapID, projectSessionID: project),
              sources.map == store.mapResultRequest(for: mapID),
              sources.identity == mapWorkflow else { return nil }
        let canonicalAsset = SourceFilePaths.canonical(URL(fileURLWithPath: assetID))
        let sourceWorkflow = store.mapSourceWorkflowIdentity(mapID)
        let matches = mapState.projectGeometryMap.sources.filter { source in
            source.capture.projectSessionID == project
                && source.capture.mapID == mapID
                && source.capture.mapWorkflowIdentity == mapWorkflow
                && source.capture.geometryCanonicalPath == canonicalAsset
        }
        guard matches.count == 1, let source = matches.first else { return nil }
        if let sourceRevision = source.snapshot?.geometryRevision, sourceRevision != revision {
            return nil
        }
        return MapOwner(projectSessionID: project, mapID: mapID,
            mapWorkflowIdentity: mapWorkflow, mapSourceWorkflowIdentity: sourceWorkflow,
            geometry: source.capture, geometryRevision: revision,
            topologyDraftState: topologySnapshot.draftState, topologyAssetID: assetID,
            mapState: mapState, sources: sources)
    }

    private static func mapOwnerIsCurrent(_ owner: MapOwner,
                                         store: WorkspaceStore,
                                         topology: GeometryTopologySession) -> Bool {
        guard let current = currentMapOwner(store: store, topology: topology) else { return false }
        return current.projectSessionID == owner.projectSessionID
            && current.mapID == owner.mapID
            && current.mapWorkflowIdentity == owner.mapWorkflowIdentity
            && current.mapSourceWorkflowIdentity == owner.mapSourceWorkflowIdentity
            && current.geometry == owner.geometry
            && current.geometryRevision == owner.geometryRevision
            && current.topologyDraftState == owner.topologyDraftState
            && current.topologyAssetID == owner.topologyAssetID
            && current.mapState === owner.mapState
            && current.sources == owner.sources
    }

    private static func selectedArcRows(topology: GeometryTopologySession,
                                        rowIDs: Set<String>) -> [GeometryTopologyFeatureRow]? {
        guard !rowIDs.isEmpty else { return nil }
        let rows = topology.table(for: "arc").rows.filter { rowIDs.contains($0.id) }
        return rows.count == rowIDs.count ? rows : nil
    }

    private static func draftFeature(snapshot: GeometryTopologySnapshot,
                                     featureKind: String,
                                     row: GeometryTopologyFeatureRow) -> GeometryTopologyMapFeature? {
        guard let features = snapshot.map?.features else { return nil }
        switch featureKind {
        case "arc":
            return unique(features.filter { $0.featureKind == "arc" && $0.fid == row.fid && $0.geometryType == "line" })
        case "node":
            return unique(features.filter { $0.featureKind == "node" && $0.fid == row.fid && $0.geometryType == "point" })
        case "region":
            return unique(features.filter { $0.featureKind == "region" && $0.geometryType == "polygon"
                && $0.selectionIDs.contains(row.id) })
        default:
            return nil
        }
    }

    private static func mapFeature(snapshot: GeometryTopologySnapshot,
                                   featureKind: String,
                                   row: GeometryTopologyFeatureRow) -> GeometryTopologyMapFeature? {
        // GeometryTopologySnapshot.map is generated from the same retained
        // topology request and source FIDs as the saved-map Geometry provider.
        // Its feature ID is therefore the map's stable selection suffix.
        draftFeature(snapshot: snapshot, featureKind: featureKind, row: row)
    }

    private static func unique(_ features: [GeometryTopologyMapFeature]) -> GeometryTopologyMapFeature? {
        features.count == 1 ? features[0] : nil
    }

    private static func exactArcLines(snapshot: GeometryTopologySnapshot,
                                      rows: [GeometryTopologyFeatureRow]) -> [MapDynamicProfileLine]? {
        guard !rows.isEmpty else { return nil }
        let ids = Set(rows.map(\.id))
        let lines = GeometryDynamicProfileLines.arcs(snapshot, selectedIDs: ids)
        guard lines.count == rows.count,
              Set(lines.map(\.id)).count == rows.count,
              rows.allSatisfy({ row in
                  lines.contains { line in
                      snapshot.map?.features.contains(where: {
                          $0.featureKind == "arc" && $0.geometryType == "line"
                              && $0.fid == row.fid && $0.id == line.id
                      }) == true
                  }
              }) else { return nil }
        return lines
    }

    private static func zoomExtent(feature: GeometryTopologyMapFeature,
                                   kind: String,
                                   currentViewport: ViewportRequest?,
                                   topologyExtent: GeometryTopologyExtent?) -> ViewportRequest? {
        let coordinates = feature.paths.flatMap { $0 }
        guard !coordinates.isEmpty,
              coordinates.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let minX = coordinates.map(\.x).min()!, maxX = coordinates.map(\.x).max()!
        let minY = coordinates.map(\.y).min()!, maxY = coordinates.map(\.y).max()!
        var width = maxX - minX
        var height = maxY - minY
        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2
        let factor: Double
        switch kind {
        case "arc", "region":
            width = max(width, 1)
            height = max(height, 1)
            factor = 1.25
        case "node":
            let baseWidth = currentViewport.map { $0.upperRight.x - $0.lowerLeft.x }
                ?? topologyExtent.map { $0.maxX - $0.minX } ?? 10
            let baseHeight = currentViewport.map { $0.upperRight.y - $0.lowerLeft.y }
                ?? topologyExtent.map { $0.maxY - $0.minY } ?? 10
            width = max(baseWidth, baseHeight) * 0.1
            height = width
            factor = 1
        default:
            return nil
        }
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        width *= factor
        height *= factor
        let request = ViewportRequest(
            lowerLeft: MapPoint(x: centerX - width / 2, y: centerY - height / 2),
            upperRight: MapPoint(x: centerX + width / 2, y: centerY + height / 2),
            animated: true, padding: 0)
        return request.isFiniteAndOrdered ? request : nil
    }
}

struct GeometryTopologyFeatureContextMenu: View {
    @ObservedObject var topology: GeometryTopologySession
    @ObservedObject var store: WorkspaceStore
    let featureKind: String
    let rowIDs: [String]
    @Binding var profileCapture: GeometryTopologyFeatureActionCapture?
    @Binding var error: String?

    private var orderedRowIDs: [String] {
        let selected = Set(rowIDs)
        return topology.table(for: featureKind).rows.filter { selected.contains($0.id) }.map(\.id)
    }
    private var canDelete: Bool { topology.canMutateTopology && !orderedRowIDs.isEmpty }

    var body: some View {
        Group {
            if let rowID = orderedRowIDs.first {
                Button("Zoom To", systemImage: "scope") {
                    Task { @MainActor in
                        topology.select(Set(orderedRowIDs), featureKind: featureKind)
                        guard let target = await GeometryTopologyFeatureActions.prepareMapTarget(
                            store: store, topology: topology, featureKind: featureKind, rowID: rowID),
                              GeometryTopologyFeatureActions.zoom(target, store: store, topology: topology) else {
                            error = L10n.text("The selected feature is no longer available in the active saved map.")
                            return
                        }
                        error = nil
                    }
                }
                if featureKind == "arc" {
                    Button("Cut Terrain Profile") { openProfile(.terrain) }
                        .disabled(orderedRowIDs.isEmpty)
                    Button("Cut Results Profile") { openProfile(.results) }
                        .disabled(orderedRowIDs.isEmpty)
                    Button("Edit Arc Points") {
                        topology.select([rowID], featureKind: "arc")
                        guard let assetID = topology.mapAssetIdentity else { return }
                        store.requestEditorToolPresentation(action: .arcPoints,
                            assetID: assetID, featureKind: "arc")
                    }
                }
                if featureKind == "region" {
                    Button("Copy Outer Region Coordinates") {
                        guard let value = topology.outerRegionCoordinates(rowID: rowID) else { return }
                        store.system.copy(value)
                    }
                    .disabled(topology.outerRegionCoordinates(rowID: rowID) == nil)
                }
                if canDelete {
                    Divider()
                    Button("Delete Selected Features", systemImage: "trash", role: .destructive) {
                        Task { @MainActor in
                            topology.select(Set(orderedRowIDs), featureKind: featureKind)
                            if !(await topology.deleteSelectedFeatures()) {
                                error = topology.error ?? L10n.text("The selected topology features could not be deleted.")
                            } else { error = nil }
                        }
                    }
                }
            }
        }
        // SwiftUI creates context-menu content when presented. Apply the same
        // row-set rule as AttributeTableDataGrid at that point, so Delete sees
        // the context row group even before the user picks a menu action.
        .onAppear {
            guard !orderedRowIDs.isEmpty else { return }
            topology.select(Set(orderedRowIDs), featureKind: featureKind)
        }
    }

    private func openProfile(_ mode: MapDynamicProfileWindowMode) {
        let targetIDs = orderedRowIDs
        guard !targetIDs.isEmpty else { return }
        topology.select(Set(targetIDs), featureKind: "arc")
        Task { @MainActor in
            guard let capture = await GeometryTopologyFeatureActions.prepareProfile(
                store: store, topology: topology, rowIDs: targetIDs, mode: mode) else {
                error = mode == .results
                    ? L10n.text("Load active result sources and select current topology arcs before cutting a Results Profile.")
                    : L10n.text("The selected topology arcs or active map sources changed before the profile could be opened.")
                return
            }
            guard GeometryTopologyFeatureActions.isCurrent(capture, store: store, topology: topology) else {
                error = L10n.text("The selected map, geometry draft, or result source changed before the profile could be opened.")
                return
            }
            error = nil
            profileCapture = capture
        }
    }
}

struct GeometryTopologyFeatureProfileSheet: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var topology: GeometryTopologySession
    let capture: GeometryTopologyFeatureActionCapture
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.text(capture.presentation.title), systemImage: "chart.xyaxis.line")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            Group {
                if GeometryTopologyFeatureActions.currentProfileCaptureIsValid(
                    capture, store: store, topology: topology),
                   let client = store.dynamicProfileBackendClient {
                    MapDynamicProfileWorkspace(store: store, mapState: capture.mapState,
                        client: client, lines: capture.lines, linesToken: capture.linesToken,
                        presentation: capture.presentation)
                        .padding(10)
                } else {
                    ContentUnavailableView("Profile source changed",
                        systemImage: "arrow.triangle.2.circlepath",
                        description: Text(L10n.text("Close this profile and reopen it from the current selected topology arcs.")))
                        .padding(20)
                }
            }
        }
        .frame(minWidth: 700, idealWidth: 940, minHeight: 460, idealHeight: 650)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
