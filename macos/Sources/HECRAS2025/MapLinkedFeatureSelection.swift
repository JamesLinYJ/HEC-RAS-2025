import Foundation
import RASWorkspaceCore
import SwiftUI

enum MapLinkedFeatureOwnerKind: String, Equatable, Sendable {
    case vector
    case boundaryCondition
    case geometry
}

/// Value identity passed through the native equivalent of Linkage.CurrentContext.
/// It keeps the exact source owner and selected feature together so a linked
/// editor/window never has to recover either from a display name.
struct MapLinkedFeatureSelectionContext: Equatable, Sendable {
    let projectSessionID: UUID
    let mapWorkflowIdentity: String
    let mapID: UUID
    let ownerKind: MapLinkedFeatureOwnerKind
    let sourceContextIdentity: String
    let sourceOwnerIdentity: String
    let sourceNodeID: String
    let sourceKind: String
    let sourceName: String
    let layerID: String
    let featureIdentity: String
    let featureLabel: String
    let featureOrdinal: Int?
    let sourcePath: String
    let sourceRevision: String?

    /// Stable source+feature reference used when a native linked consumer
    /// retains the last context while dynamic following is turned off.
    var referenceIdentity: String {
        [projectSessionID.uuidString, mapWorkflowIdentity, mapID.uuidString,
         ownerKind.rawValue, sourceContextIdentity, sourceOwnerIdentity,
         sourceNodeID, sourceKind, sourcePath, sourceRevision ?? "",
         layerID, featureIdentity]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}

@MainActor
enum MapLinkedFeatureSelectionResolver {
    static func resolve(mapState: MapState, vectorLayers: [MapVectorLayer],
                        projectSessionID: UUID, mapWorkflowIdentity: String)
        -> MapLinkedFeatureSelectionContext? {
        if let context = resolveBoundarySelection(mapState: mapState,
            projectSessionID: projectSessionID, mapWorkflowIdentity: mapWorkflowIdentity) {
            return context
        }
        if let context = resolveVectorSelection(mapState: mapState, vectorLayers: vectorLayers,
            projectSessionID: projectSessionID, mapWorkflowIdentity: mapWorkflowIdentity) {
            return context
        }
        return resolveGeometrySelection(mapState: mapState,
            projectSessionID: projectSessionID, mapWorkflowIdentity: mapWorkflowIdentity)
    }

    static func ownerIsValid(_ context: MapLinkedFeatureSelectionContext,
                             mapState: MapState, vectorLayers: [MapVectorLayer],
                             projectSessionID: UUID, mapWorkflowIdentity: String) -> Bool {
        guard context.projectSessionID == projectSessionID,
              context.mapWorkflowIdentity == mapWorkflowIdentity,
              context.mapID == mapState.id else { return false }
        switch context.ownerKind {
        case .vector:
            return vectorOwnerIsValid(context, mapState: mapState, vectorLayers: vectorLayers)
        case .boundaryCondition:
            return boundaryOwnerIsValid(context, mapState: mapState)
        case .geometry:
            return geometryOwnerIsValid(context, mapState: mapState)
        }
    }

    private static func resolveVectorSelection(mapState: MapState,
                                               vectorLayers: [MapVectorLayer],
                                               projectSessionID: UUID,
                                               mapWorkflowIdentity: String)
        -> MapLinkedFeatureSelectionContext? {
        guard let layerID = mapState.selectedLayerID,
              let featureIdentity = mapState.selectedFeatureIdentity,
              let layer = vectorLayers.first(where: { $0.id == layerID }),
              layer.isSourceVisible,
              layer.sourceMapID == nil || layer.sourceMapID == mapState.id,
              let feature = uniqueFeature(featureIdentity, in: layer) else { return nil }

        let rows = mapState.sourceMapRenderRows.filter {
            $0.mapID == mapState.id && $0.isActiveAndVisible
                && $0.payloadLayerIDs.contains(layerID)
        }
        let row: MapSourceRenderRecord
        if let active = mapState.selectedSourceContextIdentity,
           let selectedRow = rows.first(where: { $0.contextIdentity == active }) {
            row = selectedRow
        } else if rows.count == 1, let only = rows.first {
            row = only
        } else {
            return nil
        }
        let path = SourceFilePaths.canonical(layer.url)
        let revision = layer.sourceRevision
        let owner = [projectSessionID.uuidString, mapWorkflowIdentity, mapState.id.uuidString,
            row.contextIdentity, layer.id, path, revision ?? ""]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return MapLinkedFeatureSelectionContext(projectSessionID: projectSessionID,
            mapWorkflowIdentity: mapWorkflowIdentity, mapID: mapState.id,
            ownerKind: .vector, sourceContextIdentity: row.contextIdentity,
            sourceOwnerIdentity: owner, sourceNodeID: row.nodeID,
            sourceKind: row.payloadKind, sourceName: row.locator.nodeName,
            layerID: layer.id, featureIdentity: feature.stableIdentity,
            featureLabel: feature.stableIdentity, featureOrdinal: feature.sourceFeatureIndex,
            sourcePath: path, sourceRevision: revision)
    }

    private static func resolveBoundarySelection(mapState: MapState,
                                                  projectSessionID: UUID,
                                                  mapWorkflowIdentity: String)
        -> MapLinkedFeatureSelectionContext? {
        guard let selectedID = mapState.boundaryMap.selectedLineID else { return nil }
        let selectedLines = mapState.boundaryMap.visibleLines.filter { $0.id == selectedID }
        guard selectedLines.count == 1, let visibleLine = selectedLines.first,
              let entry = mapState.boundaryMap.entries.first(where: {
                  $0.capture.sourceIdentity == visibleLine.sourceIdentity
                      && $0.visibleLines.contains(where: { $0.id == visibleLine.line.id })
              }),
              entry.status == .available,
              entry.capture.projectSessionID == projectSessionID,
              entry.capture.mapWorkflowIdentity == mapWorkflowIdentity,
              entry.capture.map.mapID.caseInsensitiveCompare(mapState.id.uuidString) == .orderedSame,
              entry.capture.isChecked, entry.capture.effectiveVisible,
              let row = mapState.sourceMapRenderRows.first(where: {
                  $0.mapID == mapState.id && $0.isActiveAndVisible
                      && $0.locator.sourceIdentity == entry.capture.boundaryNode.sourceIdentity
                      && $0.payloadKind == "BoundaryCondition"
                      && $0.payloadLayerIDs.contains(selectedID)
              }) else { return nil }
        let label = visibleLine.line.name.isEmpty
            ? L10n.format("BCL: %d", visibleLine.line.sourceOrdinal) : visibleLine.line.name
        return MapLinkedFeatureSelectionContext(projectSessionID: projectSessionID,
            mapWorkflowIdentity: mapWorkflowIdentity, mapID: mapState.id,
            ownerKind: .boundaryCondition, sourceContextIdentity: row.contextIdentity,
            sourceOwnerIdentity: entry.capture.identity, sourceNodeID: row.nodeID,
            sourceKind: row.payloadKind, sourceName: row.locator.nodeName,
            layerID: "boundary:\(entry.capture.boundaryNode.sourceIdentity)",
            featureIdentity: visibleLine.line.id, featureLabel: label,
            featureOrdinal: visibleLine.line.sourceOrdinal,
            sourcePath: entry.capture.sourcePath,
            sourceRevision: entry.capture.sourceRevision)
    }

    private static func resolveGeometrySelection(mapState: MapState,
                                                  projectSessionID: UUID,
                                                  mapWorkflowIdentity: String)
        -> MapLinkedFeatureSelectionContext? {
        guard let selection = mapState.projectGeometryMap.selection else { return nil }
        let matches = mapState.projectGeometryMap.sources.filter {
            geometrySource($0, contains: selection)
        }
        guard matches.count == 1, let source = matches.first,
              let snapshot = source.snapshot,
              snapshot.geometryEffectiveVisible,
              source.capture.projectSessionID == projectSessionID,
              source.capture.mapWorkflowIdentity == mapWorkflowIdentity,
              source.capture.mapID == mapState.id else { return nil }
        return MapLinkedFeatureSelectionContext(projectSessionID: projectSessionID,
            mapWorkflowIdentity: mapWorkflowIdentity, mapID: mapState.id,
            ownerKind: .geometry, sourceContextIdentity: source.capture.identity,
            sourceOwnerIdentity: source.capture.identity,
            sourceNodeID: source.capture.geometryNode.sourceIdentity,
            sourceKind: "Geometry", sourceName: source.capture.geometryName,
            layerID: selection.layerTitle, featureIdentity: selection.id,
            featureLabel: selection.featureLabel, featureOrdinal: nil,
            sourcePath: source.capture.geometryCanonicalPath,
            sourceRevision: source.geometryRevision ?? snapshot.contextToken)
    }

    private static func vectorOwnerIsValid(_ context: MapLinkedFeatureSelectionContext,
                                           mapState: MapState,
                                           vectorLayers: [MapVectorLayer]) -> Bool {
        guard let row = mapState.sourceMapRenderRows.first(where: {
            $0.contextIdentity == context.sourceContextIdentity && $0.mapID == context.mapID
                && $0.nodeID == context.sourceNodeID && $0.payloadKind == context.sourceKind
                && $0.isActiveAndVisible && $0.payloadLayerIDs.contains(context.layerID)
        }),
              row.locator.sourceIdentity != "",
              let layer = vectorLayers.first(where: { $0.id == context.layerID }),
              layer.isSourceVisible,
              layer.sourceMapID == nil || layer.sourceMapID == context.mapID,
              SourceFilePaths.canonical(layer.url) == context.sourcePath,
              layer.sourceRevision == context.sourceRevision,
              uniqueFeature(context.featureIdentity, in: layer) != nil else { return false }
        let expectedOwner = [context.projectSessionID.uuidString,
            context.mapWorkflowIdentity, context.mapID.uuidString,
            row.contextIdentity, layer.id, context.sourcePath,
            layer.sourceRevision ?? ""]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return expectedOwner == context.sourceOwnerIdentity
    }

    private static func boundaryOwnerIsValid(_ context: MapLinkedFeatureSelectionContext,
                                             mapState: MapState) -> Bool {
        guard let entry = mapState.boundaryMap.entries.first(where: {
            $0.capture.identity == context.sourceOwnerIdentity
        }), entry.status == .available,
              entry.capture.projectSessionID == context.projectSessionID,
              entry.capture.mapWorkflowIdentity == context.mapWorkflowIdentity,
              entry.capture.map.mapID.caseInsensitiveCompare(context.mapID.uuidString) == .orderedSame,
              entry.capture.isChecked, entry.capture.effectiveVisible,
              entry.capture.sourcePath == context.sourcePath,
              entry.capture.sourceRevision == context.sourceRevision,
              entry.visibleLines.filter({ $0.id == context.featureIdentity }).count == 1,
              mapState.sourceMapRenderRows.contains(where: {
                  $0.contextIdentity == context.sourceContextIdentity
                      && $0.mapID == context.mapID && $0.nodeID == context.sourceNodeID
                      && $0.locator.sourceIdentity == entry.capture.boundaryNode.sourceIdentity
                      && $0.payloadKind == "BoundaryCondition" && $0.isActiveAndVisible
                      && $0.payloadLayerIDs.contains("\(entry.capture.sourceIdentity)|\(context.featureIdentity)")
              }) else { return false }
        return true
    }

    private static func geometryOwnerIsValid(_ context: MapLinkedFeatureSelectionContext,
                                             mapState: MapState) -> Bool {
        guard let source = mapState.projectGeometryMap.sources.first(where: {
            $0.capture.identity == context.sourceOwnerIdentity
        }), let snapshot = source.snapshot,
              snapshot.geometryEffectiveVisible,
              source.capture.projectSessionID == context.projectSessionID,
              source.capture.mapWorkflowIdentity == context.mapWorkflowIdentity,
              source.capture.mapID == context.mapID,
              source.capture.identity == context.sourceContextIdentity,
              source.capture.geometryNode.sourceIdentity == context.sourceNodeID,
              source.capture.geometryCanonicalPath == context.sourcePath,
              (source.geometryRevision ?? snapshot.contextToken) == context.sourceRevision,
              geometrySource(source, contains: context.featureIdentity,
                             layerTitle: context.layerID) else { return false }
        return true
    }

    private static func geometrySource(_ source: ProjectGeometryMapSourceState,
                                       contains selection: ProjectGeometryMapSelection) -> Bool {
        geometrySource(source, contains: selection.id, layerTitle: selection.layerTitle)
    }

    private static func geometrySource(_ source: ProjectGeometryMapSourceState,
                                       contains identity: String, layerTitle: String) -> Bool {
        guard let snapshot = source.snapshot, snapshot.geometryEffectiveVisible else { return false }
        switch layerTitle {
        case "Topology":
            guard snapshot.topologyState.effectiveVisible,
                  snapshot.topologyState.status.hasSourceData else { return false }
            return source.topologyFeatures.contains {
                identity == source.capture.identity + "|topology|" + $0.id
            }
        case "Flow Areas":
            guard snapshot.flowAreasState.effectiveVisible,
                  snapshot.flowAreasState.status.hasSourceData else { return false }
            return source.cells.contains {
                identity == source.capture.identity + "|flow-area|" + $0.id
            }
        case "Culverts":
            guard snapshot.culvertsState.effectiveVisible,
                  snapshot.culvertsState.status.hasSourceData else { return false }
            return source.culvertFeatures.contains {
                identity == source.capture.identity + "|culvert|" + $0.id
            }
        default:
            return false
        }
    }

    private static func uniqueFeature(_ identity: String,
                                      in layer: MapVectorLayer) -> MapFeature? {
        let matches = layer.features.filter {
            $0.stableIdentity == identity && $0.hasUniqueStableIdentity
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Native link state follows source selection while enabled. Turning it off
/// freezes the current feature reference, mirroring Link.IsLinked=false;
/// owner invalidation still clears a frozen reference when its source vanishes.
@MainActor
final class MapLinkedFeatureSelectionSession: ObservableObject {
    @Published private(set) var context: MapLinkedFeatureSelectionContext?
    @Published private(set) var isDynamicallyLinked = true
    private var editorSelection: (path: String, revision: String?, lineID: String)?

    func setDynamicallyLinked(_ enabled: Bool,
                              selectedContext: MapLinkedFeatureSelectionContext?,
                              ownerIsValid: (MapLinkedFeatureSelectionContext) -> Bool) {
        guard enabled != isDynamicallyLinked else { return }
        isDynamicallyLinked = enabled
        if enabled { reconcile(selectedContext: selectedContext, ownerIsValid: ownerIsValid) }
    }

    func reconcile(selectedContext: MapLinkedFeatureSelectionContext?,
                   ownerIsValid: (MapLinkedFeatureSelectionContext) -> Bool) {
        if let context, !ownerIsValid(context) {
            publish(nil)
        }
        guard isDynamicallyLinked else { return }
        publish(selectedContext)
    }

    func clear() {
        publish(nil)
    }

    /// The retained BoundaryConditionLine feature context feeds the current
    /// same-source model editor selection, matching the source linked editor's
    /// LinkContext assignment. It never searches by a display label or writes
    /// into an editor loaded for another asset.
    func propagateBoundaryContext(to editorSession: ModelEditorSession?) {
        guard let editorSession, editorSession.loaded,
              let editorPath = editorSession.modelAssetID.map({
                  SourceFilePaths.canonical(URL(fileURLWithPath: $0))
              }) else { return }

        let nextContextOwnsEditorSelection = context.map {
            $0.ownerKind == .boundaryCondition
                && $0.sourcePath == editorSelection?.path
                && $0.sourceRevision == editorSelection?.revision
                && $0.featureIdentity == editorSelection?.lineID
        } ?? false
        if let editorSelection,
           editorSelection.path == editorPath,
           editorSelection.revision == editorSession.sourceFileRevision,
           editorSession.selectedBoundaryLineID == editorSelection.lineID,
           !nextContextOwnsEditorSelection {
            editorSession.selectBoundaryLine(nil)
            self.editorSelection = nil
        }

        guard let context, context.ownerKind == .boundaryCondition,
              context.sourcePath == editorPath,
              context.sourceRevision == editorSession.sourceFileRevision,
              editorSession.boundaryLines?.lines.contains(where: {
                  $0.id == context.featureIdentity
              }) == true else { return }
        editorSession.selectBoundaryLine(context.featureIdentity)
        editorSelection = (editorPath, context.sourceRevision, context.featureIdentity)
    }

    private func publish(_ next: MapLinkedFeatureSelectionContext?) {
        guard context != next else { return }
        context = next
    }
}

/// Source action-bar equivalent. Its context and quick-edit action use the
/// linked value, so a pinned owner remains active when map selection changes.
@MainActor
struct MapLinkedFeatureSelectionView: View {
    @ObservedObject var mapState: MapState
    let vectorLayers: [MapVectorLayer]
    let projectSessionID: UUID
    let mapWorkflowIdentity: String
    let editorSession: ModelEditorSession?
    let synchronizesSession: Bool
    @StateObject private var session: MapLinkedFeatureSelectionSession
    var onQuickEdit: ((MapLinkedFeatureSelectionContext) -> Void)?
    var onContextChange: ((MapLinkedFeatureSelectionContext?) -> Void)?

    init(mapState: MapState, vectorLayers: [MapVectorLayer],
         projectSessionID: UUID, mapWorkflowIdentity: String,
         editorSession: ModelEditorSession? = nil,
         synchronizesSession: Bool = true,
         session: MapLinkedFeatureSelectionSession? = nil,
         onQuickEdit: ((MapLinkedFeatureSelectionContext) -> Void)? = nil,
         onContextChange: ((MapLinkedFeatureSelectionContext?) -> Void)? = nil) {
        self.mapState = mapState
        self.vectorLayers = vectorLayers
        self.projectSessionID = projectSessionID
        self.mapWorkflowIdentity = mapWorkflowIdentity
        self.editorSession = editorSession
        self.synchronizesSession = synchronizesSession
        _session = StateObject(wrappedValue: session ?? MapLinkedFeatureSelectionSession())
        self.onQuickEdit = onQuickEdit
        self.onContextChange = onContextChange
    }

    private var selectedContext: MapLinkedFeatureSelectionContext? {
        MapLinkedFeatureSelectionResolver.resolve(mapState: mapState,
            vectorLayers: vectorLayers, projectSessionID: projectSessionID,
            mapWorkflowIdentity: mapWorkflowIdentity)
    }

    private var linkedOwnerIsValid: Bool {
        guard let context = session.context else { return true }
        return MapLinkedFeatureSelectionResolver.ownerIsValid(context,
            mapState: mapState, vectorLayers: vectorLayers,
            projectSessionID: projectSessionID, mapWorkflowIdentity: mapWorkflowIdentity)
    }

    var body: some View {
        Group {
            if let context = session.context {
                HStack(spacing: 8) {
                    Label(title: { Text(verbatim: context.sourceName) },
                          icon: { Image(systemName: "point.3.connected.trianglepath.dotted") })
                        .font(.caption.weight(.medium)).lineLimit(1)
                    Text(verbatim: context.featureLabel)
                        .font(.caption2.monospaced()).lineLimit(1).textSelection(.enabled)
                    Toggle("Follow Selection", isOn: Binding(
                        get: { session.isDynamicallyLinked },
                        set: { session.setDynamicallyLinked($0,
                            selectedContext: selectedContext, ownerIsValid: { candidate in
                                MapLinkedFeatureSelectionResolver.ownerIsValid(candidate,
                                    mapState: mapState, vectorLayers: vectorLayers,
                                    projectSessionID: projectSessionID,
                                    mapWorkflowIdentity: mapWorkflowIdentity)
                            }) }))
                        .toggleStyle(.switch).controlSize(.mini)
                    if let onQuickEdit {
                        Button { onQuickEdit(context) } label: {
                            Label("Open Linked Context", systemImage: "arrow.up.forward.square")
                        }
                        .labelStyle(.iconOnly)
                        .help(L10n.text("Open Linked Context"))
                        .accessibilityLabel(L10n.text("Open Linked Context"))
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("map-linked-feature-context-\(context.referenceIdentity)")
            }
        }
        .onAppear {
            if synchronizesSession { synchronize() }
            onContextChange?(session.context)
        }
        .onChange(of: selectedContext) { _, _ in
            if synchronizesSession { synchronize() }
        }
        .onChange(of: linkedOwnerIsValid) { _, _ in
            if synchronizesSession { synchronize() }
        }
        .onChange(of: session.context) { _, context in onContextChange?(context) }
        .onChange(of: editorSession?.modelAssetID) { _, _ in
            if synchronizesSession { session.propagateBoundaryContext(to: editorSession) }
        }
        .onChange(of: editorSession?.loaded) { _, _ in
            if synchronizesSession { session.propagateBoundaryContext(to: editorSession) }
        }
        .onChange(of: editorSession?.sourceFileRevision) { _, _ in
            if synchronizesSession { session.propagateBoundaryContext(to: editorSession) }
        }
        .onChange(of: projectSessionID) { _, _ in
            if synchronizesSession { synchronize() }
        }
        .onChange(of: mapWorkflowIdentity) { _, _ in
            if synchronizesSession { synchronize() }
        }
    }

    private func synchronize() {
        session.reconcile(selectedContext: selectedContext) { context in
            MapLinkedFeatureSelectionResolver.ownerIsValid(context,
                mapState: mapState, vectorLayers: vectorLayers,
                projectSessionID: projectSessionID, mapWorkflowIdentity: mapWorkflowIdentity)
        }
        session.propagateBoundaryContext(to: editorSession)
    }
}
