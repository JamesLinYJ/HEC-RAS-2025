import CryptoKit
import Foundation
import RASWorkspaceCore

@MainActor
private final class WorkspaceBoundaryMapStyleProvider: BoundaryMapStyleProvider {
    private weak var store: WorkspaceStore?
    private let mapID: UUID

    init(store: WorkspaceStore, mapID: UUID) {
        self.store = store
        self.mapID = mapID
    }

    func load(_ context: BoundaryMapStyleContext) async throws -> BoundaryMapStyleSnapshot {
        guard let store, store.isCurrentBoundaryMapStyleContext(context, mapID: mapID) else {
            throw BoundaryMapStyleSessionError.staleContext
        }
        let before = try await BoundaryMapStyleFileRevision.read(context.capture.sourcePath)
        guard Self.matches(before, context.capture.sourceRevision),
              store.isCurrentBoundaryMapStyleContext(context, mapID: mapID) else {
            throw BoundaryMapStyleSessionError.sourceChanged
        }
        let loaded = try store.readBoundaryMapVisualOptions(identity: context.visualNode,
            defaults: context.defaults)
        guard let revision = loaded.revision,
              revision.caseInsensitiveCompare(context.capture.map.expectedVisualizationRevision) == .orderedSame,
              Set(loaded.options.keys) == Set([BoundaryMapRenderStyle.lineDefinitionID,
                                              BoundaryMapRenderStyle.vertexDefinitionID]) else {
            throw BoundaryMapError.mismatchedReply
        }
        let after = try await BoundaryMapStyleFileRevision.read(context.capture.sourcePath)
        guard Self.matches(after, context.capture.sourceRevision),
              store.isCurrentBoundaryMapStyleContext(context, mapID: mapID) else {
            throw BoundaryMapStyleSessionError.sourceChanged
        }
        return BoundaryMapStyleSnapshot(context: context, options: loaded.options, revision: revision)
    }

    func apply(_ context: BoundaryMapStyleContext,
               snapshot: BoundaryMapStyleSnapshot,
               options: [String: VectorVisualSettingsOptions],
               resetToDefaults: Bool) async throws -> BoundaryMapStyleSnapshot {
        guard let store, snapshot.context.identity == context.identity,
              snapshot.revision.caseInsensitiveCompare(context.capture.map.expectedVisualizationRevision) == .orderedSame,
              context.globalStyleRevision == store.vectorStyleRevision,
              Self.validDraft(options, matching: snapshot.options),
              store.isCurrentBoundaryMapStyleContext(context, mapID: mapID) else {
            throw BoundaryMapStyleSessionError.staleContext
        }
        let sourceBefore = try await BoundaryMapStyleFileRevision.read(context.capture.sourcePath)
        guard Self.matches(sourceBefore, context.capture.sourceRevision),
              store.isCurrentBoundaryMapStyleContext(context, mapID: mapID) else {
            throw BoundaryMapStyleSessionError.sourceChanged
        }
        guard store.beginAssociatedRasterStyleMutation() else { throw BoundaryMapError.unavailable }
        defer { store.endAssociatedRasterStyleMutation() }

        guard context.globalStyleRevision == store.vectorStyleRevision,
              store.isCurrentBoundaryMapStyleContext(context, mapID: mapID) else {
            throw BoundaryMapStyleSessionError.staleContext
        }
        let leasedSourceRevision = try await BoundaryMapStyleFileRevision.read(context.capture.sourcePath)
        guard Self.matches(leasedSourceRevision, context.capture.sourceRevision),
              store.isCurrentBoundaryMapStyleContext(context, mapID: mapID) else {
            throw BoundaryMapStyleSessionError.sourceChanged
        }
        let newRevision = try store.commitBoundaryMapVisualOptions(identity: context.visualNode,
            options: options, defaults: context.defaults,
            expectedRevision: snapshot.revision, resetToDefaults: resetToDefaults)
        let sourceAfterWrite = try await BoundaryMapStyleFileRevision.read(context.capture.sourcePath)
        guard Self.matches(sourceAfterWrite, context.capture.sourceRevision) else {
            throw BoundaryMapStyleSessionError.sourceChanged
        }

        await store.configureMapResultSources(mapID)
        guard let refreshedContext = try store.refreshedBoundaryMapStyleContext(
                after: context, mapID: mapID, visualizationRevision: newRevision),
              refreshedContext.globalStyleRevision == context.globalStyleRevision else {
            throw BoundaryMapStyleSessionError.staleContext
        }
        let refreshedSnapshot = try store.readBoundaryMapVisualOptions(
            identity: refreshedContext.visualNode, defaults: refreshedContext.defaults)
        guard let refreshedRevision = refreshedSnapshot.revision,
              refreshedRevision.caseInsensitiveCompare(newRevision) == .orderedSame,
              Set(refreshedSnapshot.options.keys) == Set([BoundaryMapRenderStyle.lineDefinitionID,
                                                          BoundaryMapRenderStyle.vertexDefinitionID]) else {
            throw BoundaryMapError.mismatchedReply
        }
        let finalSourceRevision = try await BoundaryMapStyleFileRevision.read(refreshedContext.capture.sourcePath)
        guard Self.matches(finalSourceRevision, refreshedContext.capture.sourceRevision),
              store.isCurrentBoundaryMapStyleContext(refreshedContext, mapID: mapID) else {
            throw BoundaryMapStyleSessionError.sourceChanged
        }
        return BoundaryMapStyleSnapshot(context: refreshedContext,
            options: refreshedSnapshot.options, revision: refreshedRevision)
    }

    private static func validDraft(_ options: [String: VectorVisualSettingsOptions],
                                   matching snapshot: [String: VectorVisualSettingsOptions]) -> Bool {
        let ids = [BoundaryMapRenderStyle.lineDefinitionID, BoundaryMapRenderStyle.vertexDefinitionID]
        guard options.count == ids.count, Set(options.keys) == Set(ids) else { return false }
        for id in ids {
            guard let option = options[id], let old = snapshot[id],
                  option.conditionGroups == old.conditionGroups,
                  option.values.validatedForPersistence() == option.values else { return false }
        }
        return true
    }

    private static func matches(_ left: String, _ right: String) -> Bool {
        left.caseInsensitiveCompare(right) == .orderedSame
    }
}

private enum BoundaryMapStyleFileRevision {
    static func read(_ path: String) async throws -> String {
        let url = URL(fileURLWithPath: path)
        let worker = Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02X", $0) }.joined()
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

extension WorkspaceStore {
    /// Reads the two style definitions for a capture already installed on its
    /// owning map. This is also used when global defaults change so maps keep
    /// rendering inherited values without borrowing another map's editor.
    func loadBoundaryMapVisualStyles(for capture: BoundaryMapCapture)
        throws -> [String: VectorVisualSettingsOptions] {
        guard let mapID = UUID(uuidString: capture.map.mapID),
              let context = try makeBoundaryMapStyleContext(capture: capture, mapID: mapID),
              let state = existingMapState(for: mapID),
              state.boundaryMap.entries.contains(where: { $0.capture.identity == capture.identity }) else {
            throw BoundaryMapStyleSessionError.staleContext
        }
        let snapshot = try readBoundaryMapVisualOptions(identity: context.visualNode,
            defaults: context.defaults)
        guard let revision = snapshot.revision,
              revision.caseInsensitiveCompare(capture.map.expectedVisualizationRevision) == .orderedSame,
              Set(snapshot.options.keys) == Set([BoundaryMapRenderStyle.lineDefinitionID,
                                                  BoundaryMapRenderStyle.vertexDefinitionID]) else {
            throw BoundaryMapError.mismatchedReply
        }
        return snapshot.options
    }

    func makeBoundaryMapStyleSession(capture: BoundaryMapCapture,
                                     mapID: UUID) async throws -> BoundaryMapStyleSession {
        guard let context = try makeBoundaryMapStyleContext(capture: capture, mapID: mapID) else {
            throw BoundaryMapStyleSessionError.staleContext
        }
        let provider = WorkspaceBoundaryMapStyleProvider(store: self, mapID: mapID)
        return BoundaryMapStyleSession(context: context, provider: provider)
    }

    private func makeBoundaryMapStyleContext(capture: BoundaryMapCapture,
                                             mapID: UUID) throws -> BoundaryMapStyleContext? {
        guard capture.projectSessionID == projectSessionID,
              capture.map.mapID.caseInsensitiveCompare(mapID.uuidString) == .orderedSame,
              let state = existingMapState(for: mapID),
              isCurrentMapState(state, mapID: mapID, projectSessionID: capture.projectSessionID),
              mapIdentityRequest(for: mapID) == capture.map,
              mapSourceWorkflowIdentity(mapID) == capture.mapWorkflowIdentity,
              state.sourceMapLayerRows.contains(where: { $0.node.sourceLocator == capture.boundaryNode }),
              state.boundaryMap.entries.contains(where: { $0.capture.identity == capture.identity }) else {
            return nil
        }
        let visualNode = try boundaryVisualNodeIdentity(capture: capture, state: state)
        let defaults = currentBoundaryVectorStyleDefaults()
        guard defaults.count == 2 else { return nil }
        return BoundaryMapStyleContext(mapID: mapID, capture: capture,
            visualNode: visualNode, defaults: defaults,
            globalStyleRevision: vectorStyleRevision)
    }

    private func boundaryVisualNodeIdentity(capture: BoundaryMapCapture,
                                            state: MapState) throws -> BoundaryVectorVisualNodeIdentity {
        guard let boundaryPath = capture.boundaryNode.nodePath, !boundaryPath.isEmpty,
              capture.boundaryNode.nodeType == "BoundaryCondition",
              let boundaryRow = state.sourceMapLayerRows.first(where: {
                  $0.node.sourceLocator == capture.boundaryNode
              }) else { throw BoundaryMapError.incompleteIdentity }
        let lineName = "Boundary Condition Lines"
        let directChildren = boundaryRow.node.children ?? []
        let lineChildren = directChildren.filter { child in
            child.sourceLocator?.nodeType == "BoundaryConditionLineLayer"
                || child.name == lineName
        }
        guard lineChildren.count == 1, let lineChild = lineChildren.first else {
            throw BoundaryMapError.incompleteIdentity
        }
        let linePath: [Int]?
        if let locator = lineChild.sourceLocator {
            guard locator.nodeType == "BoundaryConditionLineLayer",
                  locator.nodeName == lineName,
                  locator.rootName == capture.boundaryNode.rootName else {
                throw BoundaryMapError.incompleteIdentity
            }
            if let path = locator.nodePath {
                guard path.count == boundaryPath.count + 1,
                      Array(path.prefix(boundaryPath.count)) == boundaryPath else {
                    throw BoundaryMapError.incompleteIdentity
                }
                linePath = path
            } else {
                linePath = nil
            }
        } else {
            guard lineChild.name == lineName else { throw BoundaryMapError.incompleteIdentity }
            linePath = nil
        }
        return BoundaryVectorVisualNodeIdentity(mapIndex: capture.map.mapIndex,
            mapName: capture.map.mapName, mapType: capture.map.mapType,
            rootName: capture.boundaryNode.rootName, boundaryNodePath: boundaryPath,
            boundaryName: capture.boundaryNode.nodeName, lineNodePath: linePath,
            lineNodeName: lineName)
    }

    private func currentBoundaryVectorStyleDefaults() -> [String: VectorStyleValues] {
        let ids = [BoundaryMapRenderStyle.lineDefinitionID, BoundaryMapRenderStyle.vertexDefinitionID]
        return Dictionary(uniqueKeysWithValues: ids.map { ($0, effectiveVectorStyle(definitionID: $0)) })
    }

    fileprivate func isCurrentBoundaryMapStyleContext(_ context: BoundaryMapStyleContext,
                                                      mapID: UUID) -> Bool {
        guard context.mapID == mapID,
              context.capture.projectSessionID == projectSessionID,
              context.globalStyleRevision == vectorStyleRevision,
              let state = existingMapState(for: mapID),
              isCurrentMapState(state, mapID: mapID,
                  projectSessionID: context.capture.projectSessionID),
              mapIdentityRequest(for: mapID) == context.capture.map,
              mapSourceWorkflowIdentity(mapID) == context.capture.mapWorkflowIdentity,
              state.boundaryMap.entries.contains(where: { $0.capture.identity == context.capture.identity }),
              state.sourceMapLayerRows.contains(where: { $0.node.sourceLocator == context.capture.boundaryNode }),
              let identity = try? boundaryVisualNodeIdentity(capture: context.capture, state: state) else {
            return false
        }
        return identity == context.visualNode
    }

    fileprivate func refreshedBoundaryMapStyleContext(after oldContext: BoundaryMapStyleContext,
        mapID: UUID, visualizationRevision: String) throws -> BoundaryMapStyleContext? {
        guard oldContext.mapID == mapID,
              oldContext.capture.projectSessionID == projectSessionID,
              let state = existingMapState(for: mapID),
              isCurrentMapState(state, mapID: mapID,
                  projectSessionID: oldContext.capture.projectSessionID),
              let currentMap = mapIdentityRequest(for: mapID),
              Self.sameBoundaryStyleMapOwner(currentMap, as: oldContext.capture.map),
              currentMap.expectedVisualizationRevision.caseInsensitiveCompare(visualizationRevision) == .orderedSame else {
            return nil
        }
        let candidates = state.boundaryMap.entries.map(\.capture).filter {
            Self.sameBoundaryStyleCaptureOwner($0, as: oldContext.capture)
        }
        guard candidates.count == 1, let capture = candidates.first,
              capture.map == currentMap,
              let identity = try? boundaryVisualNodeIdentity(capture: capture, state: state),
              Self.sameBoundaryStyleNodeTransition(oldContext.visualNode, identity) else { return nil }
        return BoundaryMapStyleContext(mapID: mapID, capture: capture,
            visualNode: identity, defaults: currentBoundaryVectorStyleDefaults(),
            globalStyleRevision: vectorStyleRevision)
    }

    private static func sameBoundaryStyleMapOwner(_ current: MapTreeMapIdentity,
                                                  as original: MapTreeMapIdentity) -> Bool {
        current.mapID == original.mapID && current.mapIndex == original.mapIndex
            && current.mapName == original.mapName && current.mapType == original.mapType
            && current.projectPath == original.projectPath
            && current.projectXmlSHA.caseInsensitiveCompare(original.projectXmlSHA) == .orderedSame
    }

    private static func sameBoundaryStyleCaptureOwner(_ current: BoundaryMapCapture,
                                                       as original: BoundaryMapCapture) -> Bool {
        guard current.projectSessionID == original.projectSessionID,
              current.boundaryNode == original.boundaryNode,
              current.sourcePath == original.sourcePath,
              current.sourceRevision.caseInsensitiveCompare(original.sourceRevision) == .orderedSame,
              current.isChecked == original.isChecked,
              current.effectiveVisible == original.effectiveVisible,
              sameBoundaryStyleMapOwner(current.map, as: original.map) else { return false }
        switch (current.resultOwner, original.resultOwner) {
        case (nil, nil): return true
        case let (lhs?, rhs?):
            return lhs.resultNode == rhs.resultNode
                && lhs.selectionOverrides == rhs.selectionOverrides
                && lhs.selectionIndex == rhs.selectionIndex
                && lhs.selectedResultPath == rhs.selectedResultPath
                && lhs.selectedResultRevision.caseInsensitiveCompare(rhs.selectedResultRevision) == .orderedSame
        default: return false
        }
    }

    private static func sameBoundaryStyleNodeTransition(_ current: BoundaryVectorVisualNodeIdentity,
                                                        _ refreshed: BoundaryVectorVisualNodeIdentity) -> Bool {
        guard current.mapIndex == refreshed.mapIndex, current.mapName == refreshed.mapName,
              current.mapType == refreshed.mapType, current.rootName == refreshed.rootName,
              current.boundaryNodePath == refreshed.boundaryNodePath,
              current.boundaryName == refreshed.boundaryName,
              current.lineNodeName == refreshed.lineNodeName else { return false }
        if current.lineNodePath == refreshed.lineNodePath { return true }
        guard current.lineNodePath == nil, let path = refreshed.lineNodePath else { return false }
        return path.count == refreshed.boundaryNodePath.count + 1
            && Array(path.prefix(refreshed.boundaryNodePath.count)) == refreshed.boundaryNodePath
    }
}
