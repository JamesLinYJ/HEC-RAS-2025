import CryptoKit
import Foundation
import RASWorkspaceCore

/// Exact saved-map identity shared by source-tree, Geometry, and associated
/// layer requests. This is deliberately separate from Result chart contracts.
struct MapTreeMapIdentity: Codable, Hashable, Sendable {
    let projectPath: String
    let projectXml: String
    let projectXmlSHA: String
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let expectedVisualizationRevision: String
}

struct SourceMapLayerRow: Sendable {
    let node: LayerTreeNode
    let treeOrdinal: Int
    let isChecked: Bool
    let isEffectivelyVisible: Bool
    let isGeometryAssociationContext: Bool
}

private struct AssociatedRasterStyleOwners: Hashable {
    let geometryNodes: [CatalogTreeNodeLocator]
    let planNodes: [CatalogTreeNodeLocator]
    let resultOwner: MapResultGeometryOwner?
}

extension WorkspaceStore {
    func addAssetsToMap(_ selected: [ProjectAsset], mapID: UUID) async {
        guard !isSavingAll, !isRunningProjectTool, !isOpeningProject, !isClosingTab,
              mapState(for: mapID).kind != .unsupported,
              let ownerURL = document?.url,
              let provider = layerTreeProvider as? BackendMapTreeProvider else { return }
        let project = projectSessionID
        for asset in selected {
            guard project == projectSessionID, document?.url == ownerURL else { return }
            do {
                if asset.section == .results {
                    if [.buildable, .plan, .geometry].contains(mapDocument(for: mapID)?.kind ?? .unsupported) {
                        let revision = try await Self.mapSourceRevision(asset.url)
                        guard project == projectSessionID, document?.url == ownerURL else { return }
                        _ = try await provider.addResult(resultPath: SourceFilePaths.canonical(asset.url), revision: revision,
                            context: sourceMapTreeContext(mapID))
                    }
                    await configureMapResultSources(mapID)
                } else if ["tif", "tiff"].contains(asset.url.pathExtension.lowercased()) {
                    guard await connectRasterSource(asset.url, for: mapID) else { return }
                } else if asset.url.pathExtension.lowercased() == "shp" {
                    guard await connectVectorSource(asset.url, for: mapID) else { return }
                } else if ["geojson", "json"].contains(asset.url.pathExtension.lowercased()) {
                    let revision = try await Self.mapSourceRevision(asset.url)
                    guard project == projectSessionID, let document, document.url == ownerURL,
                          let projectRevision = document.sourceRevision else { return }
                    let imported = try await provider.importGeoJSONVector(sourcePath: asset.url.standardizedFileURL.path, revision: revision,
                        projectXML: document.editorXML(overridingDescription: descriptionDraft), projectRevision: projectRevision,
                        context: sourceMapTreeContext(mapID))
                    guard project == projectSessionID else { return }
                    includeMapLayer(asset.id, in: mapID)
                    await configureMapResultSources(mapID)
                    guard project == projectSessionID else { return }
                    if let warning = imported.refreshWarning {
                        errorMessage = L10n.format("The layer was imported, but the map could not be refreshed: %@.", warning)
                    }
                } else { includeMapLayer(asset.id, in: mapID) }
            } catch is CancellationError {
                return
            } catch {
                if projectSessionID == project { errorMessage = L10n.text(error.localizedDescription) }
                return
            }
        }
    }

    func sourceMapLayerNodes(_ mapID: UUID) async throws -> [LayerTreeNode] {
        let rows = try await sourceMapLayerRows(mapID)
        return rows.map(\.node)
    }

    func sourceMapLayerRows(_ mapID: UUID) async throws -> [SourceMapLayerRow] {
        guard mapIdentityRequest(for: mapID) != nil else { throw CancellationError() }
        return try await sourceMapLayerRows(mapID, context: sourceMapTreeContext(mapID))
    }

    /// Loads and installs rows for one exact map-tree request. Callers that
    /// must bind result-owned children capture the context before suspension,
    /// so the tree and the later captures share the same slot-zero override.
    private func sourceMapLayerRows(_ mapID: UUID, context: LayerTreeContext) async throws -> [SourceMapLayerRow] {
        guard let provider = layerTreeProvider as? BackendMapTreeProvider else { return [] }
        guard mapIdentityRequest(for: mapID) != nil else { throw CancellationError() }
        let projectSession = projectSessionID
        let state = existingMapState(for: mapID) ?? mapState(for: mapID)
        let identity = mapWorkflowIdentity(mapID)
        let previousBindings = Dictionary((state.sourceVectorBindings ?? []).map { ($0.id, $0) },
                                          uniquingKeysWith: { _, current in current })
        guard isCurrentMapState(state, mapID: mapID, projectSessionID: projectSession),
              sourceMapTreeContext(mapID) == context else { throw CancellationError() }
        let snapshot = try await provider.load(context)
        guard !Task.isCancelled,
              isCurrentMapState(state, mapID: mapID, projectSessionID: projectSession),
              mapIdentityRequest(for: mapID) != nil,
              mapWorkflowIdentity(mapID) == identity,
              sourceMapTreeContext(mapID) == context else { throw CancellationError() }
        var kinds: [String: Set<String>] = [:]
        var bindings: [MapVectorInstanceBinding] = []
        func gather(_ node: LayerTreeNode, ancestorEnabled: Bool) {
            let checked: Bool
            switch node.checked {
            case .unchecked, .mixed: checked = false
            case .checked: checked = true
            case nil:
                // Backend vector nodes omit Checked when their source is
                // unusable; folders omit it because they are not checkable.
                checked = sourceMapVectorKind(node) == nil
            }
            let enabled = ancestorEnabled && checked
            let bindingID = sourceVectorInstanceID(node, mapID: mapID)
            let identityPath: String?
            if node.assetID == nil, let previous = previousBindings[bindingID] {
                // The Host intentionally omits AssetID for an unavailable
                // source. Keep the last verified path for this persisted node
                // identity so it stays hidden while cached geometry is pruned.
                identityPath = previous.sourcePath
            } else {
                identityPath = sourceMapVectorIdentityURL(node).map(SourceFilePaths.canonical)
            }
            if let path = identityPath, let type = node.sourceLocator?.mapType {
                if kinds[path] == nil { kinds[path] = [] }
                if enabled { kinds[path, default: []].insert(type) }
                if let kind = sourceMapVectorKind(node) {
                    bindings.append(MapVectorInstanceBinding(id: bindingID, sourcePath: path,
                        name: node.name, kind: kind, isVisible: enabled))
                }
            }
            for child in node.children ?? [] { gather(child, ancestorEnabled: enabled) }
        }
        for root in snapshot.roots { gather(root, ancestorEnabled: true) }
        state.sourceVectorKinds = kinds
        state.sourceVectorBindings = bindings
        if let hidden = snapshot.hiddenLayerIDs {
            // Source file membership and source node visibility are separate.
            // A hidden sibling must never hide every instance of its file.
            let instanceIDs = Set(bindings.map(\.id))
            state.hiddenLayers = state.hiddenLayers.intersection(instanceIDs).union(hidden.filter {
                !kinds.keys.contains(SourceFilePaths.canonical(URL(fileURLWithPath: $0)))
            })
        }
        let associatedTypes: Set<String> = ["Terrain", "NValue", "Classification"]
        var treeOrdinal = 0
        func flatten(_ node: LayerTreeNode, ancestorEnabled: Bool,
                     insideGeometry: Bool, insideMatchingLayers: Bool) -> [SourceMapLayerRow] {
            let ownChecked: Bool
            switch node.checked {
            case .checked: ownChecked = true
            case .unchecked, .mixed, nil: ownChecked = false
            }
            // Non-checkable folders have nil Checked and do not disable their
            // descendants. Checkable map/Geometry/associated nodes gate them.
            let effective = ancestorEnabled && (node.checked == nil || ownChecked)
            let kind = node.sourceLocator?.nodeType
            let associationLocator = node.sourceLocator
            let hasAssociationIdentity = associationLocator?.associationKind != nil
                || associationLocator?.associationAssetID != nil
                || associationLocator?.parentGeometryAssetID != nil
                || associationLocator?.parentGeometryNodePath != nil
                || associationLocator?.parentGeometryNodeName != nil
                || associationLocator?.parentPlanAssetID != nil
                || associationLocator?.parentPlanNodePath != nil
                || associationLocator?.parentPlanNodeName != nil
                || associationLocator?.parentResultNodeType != nil
                || associationLocator?.parentResultAssetID != nil
                || associationLocator?.parentResultNodePath != nil
                || associationLocator?.parentResultNodeName != nil
            let isAssociationContext = associatedTypes.contains(kind ?? "")
                && (hasAssociationIdentity || insideGeometry || insideMatchingLayers)
            let row: [SourceMapLayerRow]
            if ["MapLayer", "Plan", "Result", "MultiResult", "Geometry", "ConceptualMesh", "FlowAreaLayer",
                "CulvertBarrelLayer", "Terrain", "NValue", "Classification", "BoundaryCondition", "WindLayer"].contains(kind ?? "") {
                row = [.init(node: node, treeOrdinal: treeOrdinal, isChecked: ownChecked,
                    isEffectivelyVisible: effective, isGeometryAssociationContext: isAssociationContext)]
                treeOrdinal += 1
            } else {
                row = []
            }
            let nextInsideGeometry = insideGeometry || kind == "Geometry"
            let nextInsideMatchingLayers = insideMatchingLayers
                || (node.name == "Matching Layers"
                    && ["MatchingGeometryLayersSectionContext", "MatchingPlanLayersSectionContext"]
                        .contains(node.sourceClass))
            return row + (node.children ?? []).flatMap {
                flatten($0, ancestorEnabled: effective,
                        insideGeometry: nextInsideGeometry,
                        insideMatchingLayers: nextInsideMatchingLayers)
            }
        }
        let rows = snapshot.roots.flatMap {
            flatten($0, ancestorEnabled: true, insideGeometry: false, insideMatchingLayers: false)
        }
        state.installSourceMapLayerRows(rows)
        state.installSourceMapRenderRows(makeSourceRenderRecords(rows, mapID: mapID))
        return rows
    }

    private func makeSourceRenderRecords(_ rows: [SourceMapLayerRow], mapID: UUID) -> [MapSourceRenderRecord] {
        let state = mapState(for: mapID)
        let rasterRows = rows.filter { row in
            guard let locator = row.node.sourceLocator else { return false }
            return locator.nodeType == "Raster" || locator.nodeType == "DiscreteRaster"
                || locator.nodeType == "Terrain" || locator.nodeType == "NValue" || locator.nodeType == "Classification"
        }
        let lastRasterOrdinal = rasterRows.last?.treeOrdinal
        return rows.compactMap { row in
            guard let locator = row.node.sourceLocator else { return nil }
            let kind = locator.nodeType
            // Focused Plan rows are tree owners, not paintable source layers.
            // Keep them in `SourceMapLayerRow` for exact association-owner
            // resolution, but never synthesize a composition record for them.
            guard kind != "Plan" else { return nil }
            let family: Int
            switch kind {
            case "Terrain": family = 0
            case "Classification": family = 1
            case "NValue": family = 2
            case "Result", "MultiResult", "Raster", "DiscreteRaster": family = 3
            case "Geometry", "ConceptualMesh", "FlowAreaLayer", "CulvertBarrelLayer": family = 4
            case "BoundaryCondition", "WindLayer": family = 5
            case "MapLayer": family = 6
            default: family = 7
            }
            let contextIdentity = "\(mapID.uuidString)|\(locator.sourceIdentity)"
            let payloadIDs: [String]
            let activeOrdinal: Int?
            switch kind {
            case "Result", "MultiResult":
                let layers = state.resultMap.layers(for: locator)
                payloadIDs = layers.map(\.id)
                activeOrdinal = state.resultSources.sources?.activeNodes.firstIndex(where: { $0.node == locator })
            case "Geometry", "ConceptualMesh", "FlowAreaLayer", "CulvertBarrelLayer":
                payloadIDs = state.projectGeometryMap.sources.compactMap { source in
                    guard let snapshot = source.snapshot else { return nil }
                    if source.capture.geometryNode == locator { return source.capture.identity }
                    let childLocators = [snapshot.topologyState.locator, snapshot.flowAreasState.locator,
                        snapshot.culvertsState.locator].compactMap { $0 }
                    return childLocators.contains(locator) ? source.capture.identity + "|" + locator.sourceIdentity : nil
                }
                activeOrdinal = state.projectGeometryMap.sources.firstIndex { $0.capture.geometryNode == locator }
            case "Terrain", "NValue", "Classification":
                payloadIDs = state.associatedMapLayers.entries.filter {
                    $0.capture.associationNode == locator
                }.compactMap { $0.rasterLayer?.id }
                activeOrdinal = state.associatedMapLayers.entries.firstIndex { $0.capture.associationNode == locator }
            case "BoundaryCondition":
                payloadIDs = state.boundaryMap.entries.filter { $0.capture.boundaryNode == locator }
                    .flatMap { $0.visibleLines.map(\.id) }
                activeOrdinal = state.boundaryMap.entries.firstIndex { $0.capture.boundaryNode == locator }
            case "WindLayer":
                // Wind is a source context for the velocity sampler, not a
                // paint layer. Its exact child locator is retained in the row.
                payloadIDs = []
                activeOrdinal = nil
            case "MapLayer":
                let vectorID = sourceVectorInstanceID(row.node, mapID: mapID)
                if sourceMapVectorKind(row.node) != nil {
                    payloadIDs = state.vectors(mapLayers).contains(where: { $0.id == vectorID }) ? [vectorID] : []
                    activeOrdinal = state.vectors(mapLayers).firstIndex(where: { $0.id == vectorID })
                } else {
                    let rasters = rasterMapSources.filter {
                        $0.sourceMapID == mapID && $0.nodePath == locator.nodePath
                    }.map(\.id)
                    payloadIDs = rasters
                    activeOrdinal = rasters.first.flatMap { id in
                        state.rasters(rasterLayers).firstIndex(where: { $0.id == id })
                    }
                }
            default:
                payloadIDs = []
                activeOrdinal = nil
            }
            return MapSourceRenderRecord(mapID: mapID, nodeID: row.node.id, locator: locator,
                familyOrder: family, treeOrdinal: row.treeOrdinal, activeLayerOrdinal: activeOrdinal,
                contextIdentity: contextIdentity, payloadKind: kind, payloadLayerIDs: payloadIDs,
                isChecked: row.isChecked, isEffectivelyVisible: row.isEffectivelyVisible,
                isStatic: false, staticInsertionAfterRaster: row.treeOrdinal == lastRasterOrdinal)
        }
    }

    func removeMapSourceNode(_ node: LayerTreeNode, mapID: UUID) async -> Bool {
        guard !isSavingAll, !isRunningProjectTool, !isOpeningProject, !isClosingTab,
              let provider = layerTreeProvider as? BackendMapTreeProvider else { return false }
        let project = projectSessionID
        let removedLayerIDs = rasterMapSources.filter {
            $0.sourceMapID == mapID && $0.nodePath == node.sourceLocator?.nodePath
                && node.sourceLocator?.mapType == "SingleBandRasterMapLayer"
        }.map(\.id)
        do {
            var sourcePath: String?
            var revision: String?
            if node.sourceLocator?.nodeType == "MapLayer" {
                let file = node.assetID ?? node.sourceLocator?.filename ?? node.sourceLocator?.filenameRelative
                guard let file, let directory = document?.directory else { return false }
                let url = file.hasPrefix("/") ? URL(fileURLWithPath: file) : directory.appendingPathComponent(file)
                sourcePath = SourceFilePaths.canonical(url)
                let editor = mapState(for: mapID).polylineEditor
                guard !(editor.hasUnsavedChanges || editor.isBusy) || editor.currentScope?.canonicalPath != sourcePath else {
                    errorMessage = L10n.text("Save or discard the line edits before removing their map layer."); return false
                }
                revision = try await Self.mapSourceRevision(url)
            }
            _ = try await provider.removeSourceNode(nodeID: node.id, sourcePath: sourcePath, revision: revision,
                context: sourceMapTreeContext(mapID))
            guard project == projectSessionID else { return false }
            mapState(for: mapID).removeLayer(sourceVectorInstanceID(node, mapID: mapID))
            for layerID in removedLayerIDs { mapState(for: mapID).removeLayer(layerID) }
            await configureMapResultSources(mapID)
            return true
        } catch { if project == projectSessionID { errorMessage = L10n.text(error.localizedDescription) }; return false }
    }

    nonisolated private static func mapSourceRevision(_ url: URL) async throws -> String {
        try await Task.detached {
            SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02X", $0) }.joined()
        }.value
    }

    func mapResultRequest(for mapID: UUID) -> MapResultChartMapRequest? {
        guard ["Project", "Buildable", "Plan", "Geometry"].contains(catalogMapDocuments.first(where: { $0.id == mapID.uuidString })?.kind ?? ""),
              let identity = mapIdentityRequest(for: mapID) else { return nil }
        return .init(projectPath: identity.projectPath, projectXml: identity.projectXml,
            projectXmlSHA: identity.projectXmlSHA, mapID: identity.mapID, mapIndex: identity.mapIndex,
            mapName: identity.mapName, mapType: identity.mapType,
            expectedVisualizationRevision: identity.expectedVisualizationRevision,
            computeReadLease: mapResultComputeReadLease)
    }

    /// Builds a current, exact .vis map identity for tree/geometry/associated
    /// layer routes. It does not imply that a particular source endpoint
    /// supports every saved map type.
    func mapIdentityRequest(for mapID: UUID) -> MapTreeMapIdentity? {
        guard modelProvider is BackendModelProvider, let document, let url = document.url,
              let map = catalogMapDocuments.first(where: { $0.id.caseInsensitiveCompare(mapID.uuidString) == .orderedSame }),
              let index = map.sourceIndex, let revision = map.visualizationRevision else { return nil }
        let xml = document.editorXML(overridingDescription: descriptionDraft)
        let sha = SHA256.hash(data: Data(xml.utf8)).map { String(format: "%02X", $0) }.joined()
        return .init(projectPath: url.standardizedFileURL.path, projectXml: xml, projectXmlSHA: sha,
            mapID: mapID.uuidString, mapIndex: index, mapName: map.name, mapType: map.kind,
            expectedVisualizationRevision: revision)
    }

    /// A successful map-tree action advances the .vis revision. Compare the
    /// stable saved-map owner after the write while allowing that expected
    /// revision change; index/name alone are insufficient when .vis permits
    /// duplicate map names.
    private func sameSavedMapOwner(_ current: MapTreeMapIdentity?, as original: MapTreeMapIdentity) -> Bool {
        guard let current else { return false }
        return current.mapID == original.mapID
            && current.mapIndex == original.mapIndex
            && current.mapName == original.mapName
            && current.mapType == original.mapType
            && current.projectPath == original.projectPath
            && current.projectXmlSHA.caseInsensitiveCompare(original.projectXmlSHA) == .orderedSame
    }

    func mapWorkflowIdentity(_ mapID: UUID) -> String {
        guard let map = mapIdentityRequest(for: mapID) else { return projectSessionID.uuidString + "|unavailable|" + mapID.uuidString }
        return [projectSessionID.uuidString, String(assetsRevision), map.mapID, String(map.mapIndex), map.mapName, map.mapType,
                map.projectPath, map.projectXmlSHA, map.expectedVisualizationRevision].joined(separator: "|")
    }

    /// The selected MultiResult slot changes the actual embedded Geometry and
    /// Boundary objects even though the map's `.vis` revision is unchanged.
    /// Include the backend chart token and canonical slot state in every tree
    /// child capture identity so a late source page cannot survive a selection.
    func mapSourceWorkflowIdentity(_ mapID: UUID) -> String {
        let base = mapWorkflowIdentity(mapID)
        guard let state = existingMapState(for: mapID),
              let snapshot = state.resultSources.snapshot else { return base + "|result-context:none" }
        return mapSourceWorkflowIdentity(base: base, snapshot: snapshot)
    }

    private func mapSourceWorkflowIdentity(base: String, snapshot: MapResultSourcesSnapshot) -> String {
        let slots = snapshot.selectionOverrides.sorted {
            ($0.nodeIdentity, $0.selectionIndex) < ($1.nodeIdentity, $1.selectionIndex)
        }.map { item in
            [item.nodeIdentity, String(item.selectionIndex), item.mode.rawValue,
             item.resultPath.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0)) } ?? "",
             item.resultRevision?.uppercased() ?? ""].joined(separator: ":")
        }.joined(separator: "\u{1e}")
        return base + "|result-context:" + snapshot.sources.contextToken + "|slots:" + slots
    }

    private func mapSourceWorkflowIdentity(_ mapID: UUID, state: MapState,
                                          projectSessionID expectedSession: UUID) -> String? {
        guard isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
              let map = mapIdentityRequest(for: mapID) else { return nil }
        let base = [expectedSession.uuidString, String(assetsRevision), map.mapID,
            String(map.mapIndex), map.mapName, map.mapType, map.projectPath,
            map.projectXmlSHA, map.expectedVisualizationRevision].joined(separator: "|")
        guard let snapshot = state.resultSources.snapshot else { return base + "|result-context:none" }
        return mapSourceWorkflowIdentity(base: base, snapshot: snapshot)
    }

    /// Exact pending setup identity for an already-created map state. This is
    /// intentionally non-creating so tests and callers can check whether a
    /// setup flight still belongs to a live map after deletion/reset.
    func mapResultSourceSetupRequestIdentity(for mapID: UUID) -> String? {
        guard let state = existingMapState(for: mapID),
              let map = mapIdentityRequest(for: mapID) else { return nil }
        return mapResultSourceSetupRequestIdentity(mapID, state: state,
            projectSessionID: projectSessionID, map: map)
    }

    private func mapResultSourceSetupRequestIdentity(_ mapID: UUID, state: MapState,
                                                      projectSessionID expectedSession: UUID,
                                                      map: MapTreeMapIdentity? = nil) -> String? {
        guard isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
              let map = map ?? mapIdentityRequest(for: mapID) else { return nil }
        let overrides = state.resultSelectionOverrides.sorted {
            ($0.nodeIdentity, $0.selectionIndex) < ($1.nodeIdentity, $1.selectionIndex)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encodedOverrides = (try? encoder.encode(overrides))?.base64EncodedString() ?? "invalid"
        let workflowIdentity = [expectedSession.uuidString, String(assetsRevision), map.mapID,
            String(map.mapIndex), map.mapName, map.mapType, map.projectPath,
            map.projectXmlSHA, map.expectedVisualizationRevision].joined(separator: "|")
        return workflowIdentity + "|requested-slots:" + encodedOverrides
    }

    func configureMapResultSources(_ mapID: UUID) async {
        guard !Task.isCancelled, !isRunningPlanCompute,
              mapIdentityRequest(for: mapID) != nil else { return }
        let capturedProjectSessionID = projectSessionID
        let state = existingMapState(for: mapID) ?? mapState(for: mapID)
        guard isCurrentMapState(state, mapID: mapID, projectSessionID: capturedProjectSessionID) else { return }

        while !Task.isCancelled {
            guard let requestIdentity = mapResultSourceSetupRequestIdentity(mapID, state: state,
                projectSessionID: capturedProjectSessionID) else { return }
            if let flight = mapResultSourceSetupCoordinator.flight(for: mapID),
               flight.requestIdentity == requestIdentity {
                await flight.task.value
                guard !Task.isCancelled,
                      isCurrentMapState(state, mapID: mapID, projectSessionID: capturedProjectSessionID),
                      let currentIdentity = mapResultSourceSetupRequestIdentity(mapID, state: state,
                        projectSessionID: capturedProjectSessionID) else { return }
                if currentIdentity == requestIdentity {
                    if let replacement = mapResultSourceSetupCoordinator.flight(for: mapID),
                       replacement.token != flight.token { continue }
                    return
                }
                continue
            }

            let token = UUID()
            let task = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled,
                      self.isCurrentMapState(state, mapID: mapID, projectSessionID: capturedProjectSessionID),
                      self.mapResultSourceSetupRequestIdentity(mapID, state: state,
                        projectSessionID: capturedProjectSessionID) == requestIdentity else { return }
                await self.performMapResultSourcesConfiguration(mapID, state: state,
                    projectSessionID: capturedProjectSessionID, requestIdentity: requestIdentity)
            }
            mapResultSourceSetupCoordinator.replace(.init(requestIdentity: requestIdentity,
                token: token, task: task), for: mapID)
            await task.value
            mapResultSourceSetupCoordinator.finish(mapID: mapID, token: token)
            guard !Task.isCancelled,
                  isCurrentMapState(state, mapID: mapID, projectSessionID: capturedProjectSessionID),
                  let currentIdentity = mapResultSourceSetupRequestIdentity(mapID, state: state,
                    projectSessionID: capturedProjectSessionID) else { return }
            if currentIdentity == requestIdentity {
                if let replacement = mapResultSourceSetupCoordinator.flight(for: mapID),
                   replacement.token != token { continue }
                return
            }
        }
    }

    private func performMapResultSourcesConfiguration(_ mapID: UUID, state: MapState,
                                                      projectSessionID expectedSession: UUID,
                                                      requestIdentity: String) async {
        guard !Task.isCancelled, !isRunningPlanCompute,
              mapResultSourceSetupRequestIdentity(mapID, state: state,
                projectSessionID: expectedSession) == requestIdentity else { return }
        let mapIdentity = mapWorkflowIdentity(mapID)
        guard let map = mapIdentityRequest(for: mapID) else {
            return
        }
        guard isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession) else { return }
        let supportsResultWorkflow = ["Project", "Buildable", "Plan", "Geometry"].contains(map.mapType)
        let resultMap = supportsResultWorkflow ? mapResultRequest(for: mapID) : nil
        if state.resultMapIdentity != mapIdentity || state.resultSources.isStale {
            state.resultMapIdentity = mapIdentity
            state.resultSourceIdentity = nil
            state.resultSourceSetupGeneration &+= 1
            invalidateMapCharts(mapID: mapID)
            state.resultMap.invalidate()
            if let resultMap {
                state.resultSources.configure(map: resultMap, identity: mapIdentity, selectionOverrides: state.resultSelectionOverrides,
                    canReadSource: { [weak self] in
                        self?.isRunningPlanCompute == false
                            && self?.isRunningInitialConditionsCommit == false
                    },
                    isCurrent: { [weak self, weak state] in
                        guard let self, let state else { return false }
                        return self.isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession)
                            && self.mapWorkflowIdentity(mapID) == mapIdentity
                    },
                    selectionOverridesDidChange: { [weak self, weak state] overrides in
                        guard let self, let state,
                              self.isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
                              self.mapWorkflowIdentity(mapID) == mapIdentity else { return }
                        state.resultSelectionOverrides = overrides
                        self.invalidateMapCharts(mapID: mapID)
                        state.resultSourceIdentity = nil
                        Task { @MainActor [weak self] in await self?.configureMapResultSources(mapID) }
                    },
                    sourcesDidChange: { [weak self, weak state] in
                        guard let self, let state,
                              self.isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
                              self.mapWorkflowIdentity(mapID) == mapIdentity,
                              let snapshot = state.resultSources.snapshot,
                              snapshot.map == resultMap,
                              snapshot.identity == mapIdentity else { return }
                        Task { @MainActor [weak self, weak state] in
                            guard let self, let state, !Task.isCancelled,
                                  self.isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
                                  self.mapWorkflowIdentity(mapID) == mapIdentity,
                                  let snapshot = state.resultSources.snapshot,
                                  snapshot.map == resultMap,
                                  snapshot.identity == mapIdentity else { return }
                            await self.configureMapResultSources(mapID)
                        }
                    },
                    liveSelectionDidChange: { [weak self, weak state] nodeID, selectionIndex, mode, entry, timeline, storedChoice in
                        guard let self, let state,
                              self.isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
                              self.mapWorkflowIdentity(mapID) == mapIdentity else { return }
                        state.resultMap.updateLiveComputeSelection(nodeID: nodeID,
                            selectionIndex: selectionIndex, selectionMode: mode,
                            entry: entry, timeline: timeline,
                            selectedStoredChoice: storedChoice)
                    },
                    liveSelectionSlotDidRemove: { [weak self, weak state] nodeID, selectionIndex in
                        guard let self, let state,
                              self.isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
                              self.mapWorkflowIdentity(mapID) == mapIdentity else { return }
                        state.resultMap.removeLiveComputeSelectionSlot(nodeID: nodeID,
                            selectionIndex: selectionIndex)
                    },
                    confirmedLiveResultDidChange: { [weak self] entry in
                        self?.retireConfirmedLiveResultCompute(entry)
                    })
            } else {
                state.resultSources.invalidate()
                state.resultSelectionOverrides = []
            }
        }
        if let resultMap {
            let sourcesReady = await state.resultSources.loadSources()
            guard !Task.isCancelled,
                  isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
                  sourcesReady,
                  let snapshot = state.resultSources.snapshot,
                  snapshot.map == resultMap,
                  snapshot.identity == mapIdentity,
                  mapWorkflowIdentity(mapID) == mapIdentity,
                  mapResultSourceSetupRequestIdentity(mapID, state: state,
                    projectSessionID: expectedSession) == requestIdentity else { return }
            configureMapResultRendering(mapID)
        }

        guard let identity = mapSourceWorkflowIdentity(mapID, state: state,
            projectSessionID: expectedSession) else { return }
        configureTerrainInputMap(mapID: mapID, state: state, projectSessionID: expectedSession,
            workflowIdentity: identity)
        state.projectGeometryMap.invalidateIfWorkflowChanged(identity)
        if state.resultSourceIdentity != identity {
            state.resultSourceSetupGeneration &+= 1
            let generation = state.resultSourceSetupGeneration
            invalidateMapCharts(mapID: mapID)
            state.storedCulvertProfile.invalidate()
            do {
                let rows = try await sourceMapLayerRows(mapID)
                let nodes = rows.map(\.node)
                guard !Task.isCancelled,
                      isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
                      mapSourceWorkflowIdentity(mapID, state: state, projectSessionID: expectedSession) == identity,
                      state.resultSourceSetupGeneration == generation,
                      mapResultSourceSetupRequestIdentity(mapID, state: state,
                        projectSessionID: expectedSession) == requestIdentity else { return }
                await refreshSourceMapVectors(nodes, mapID: mapID)
                guard !Task.isCancelled,
                      isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
                      mapSourceWorkflowIdentity(mapID, state: state, projectSessionID: expectedSession) == identity,
                      state.resultSourceSetupGeneration == generation,
                      mapResultSourceSetupRequestIdentity(mapID, state: state,
                        projectSessionID: expectedSession) == requestIdentity else { return }
                await configureProjectGeometryMap(mapID, map: map, identity: identity, rows: rows)
                guard !Task.isCancelled,
                      isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
                      mapSourceWorkflowIdentity(mapID, state: state, projectSessionID: expectedSession) == identity,
                      state.resultSourceSetupGeneration == generation,
                      mapResultSourceSetupRequestIdentity(mapID, state: state,
                        projectSessionID: expectedSession) == requestIdentity else { return }
                await configureAssociatedMapLayers(mapID, map: map, identity: identity, rows: rows)
                guard !Task.isCancelled,
                      isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
                      mapSourceWorkflowIdentity(mapID, state: state, projectSessionID: expectedSession) == identity,
                      state.resultSourceSetupGeneration == generation,
                      mapResultSourceSetupRequestIdentity(mapID, state: state,
                        projectSessionID: expectedSession) == requestIdentity else { return }
                await configureBoundaryMap(mapID, map: map, identity: identity, rows: rows)
                guard !Task.isCancelled,
                      isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
                      mapSourceWorkflowIdentity(mapID, state: state, projectSessionID: expectedSession) == identity,
                      state.resultSourceSetupGeneration == generation,
                      mapResultSourceSetupRequestIdentity(mapID, state: state,
                        projectSessionID: expectedSession) == requestIdentity else { return }
                configureStoredCulvertProfile(mapID)
                guard !Task.isCancelled,
                      isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
                      mapSourceWorkflowIdentity(mapID, state: state, projectSessionID: expectedSession) == identity,
                      state.resultSourceSetupGeneration == generation,
                      mapResultSourceSetupRequestIdentity(mapID, state: state,
                        projectSessionID: expectedSession) == requestIdentity else { return }
                state.resultSourceIdentity = identity
            } catch {
                guard !Task.isCancelled,
                      isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
                      mapSourceWorkflowIdentity(mapID, state: state, projectSessionID: expectedSession) == identity,
                      state.resultSourceSetupGeneration == generation,
                      mapResultSourceSetupRequestIdentity(mapID, state: state,
                        projectSessionID: expectedSession) == requestIdentity else { return }
                if error is CancellationError || Task.isCancelled { return }
                state.sourceVectorPaths = []; state.sourceVectorBindings = []
                state.projectGeometryMap.reportConfigurationError(error.localizedDescription)
                state.associatedMapLayers.invalidate()
                state.boundaryCaptureGeneration &+= 1
                state.boundaryMap.invalidate()
                state.storedCulvertProfile.invalidate()
                errorMessage = L10n.text(error.localizedDescription)
            }
        }
        // A map with no vector or Geometry features has no camera extent yet.
        // Ask the associated-source session for real finite source bounds so
        // the first camera fit can produce the normal viewport request.
        guard !Task.isCancelled,
              isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession) else { return }
        await state.associatedMapLayers.bootstrapSourceExtents()
        guard !Task.isCancelled,
              isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession) else { return }
        state.projectGeometryMap.resumeInterruptedPaging()
        await configureWindVelocityParticles(mapID: mapID)
    }

    /// Loads stored culvert output only for the currently selected, visible
    /// Result/MultiResult row on this map. The captured timeline and exact
    /// Result source context both come from this MapState; another open map
    /// cannot supply its keyframe or HDF identity.
    func configureStoredCulvertProfile(_ mapID: UUID) {
        guard let state = existingMapState(for: mapID) else { return }
        guard let map = mapIdentityRequest(for: mapID),
              isCurrentMapState(state, mapID: mapID, projectSessionID: projectSessionID),
              let snapshot = state.resultSources.snapshot,
              let selectedContext = state.selectedSourceContextIdentity,
              let row = state.sourceMapRenderRows.first(where: {
                  $0.contextIdentity == selectedContext && $0.isActiveAndVisible
                      && ["Result", "MultiResult"].contains($0.payloadKind)
              }),
              let active = snapshot.sources.activeNodes.first(where: { $0.node == row.locator }),
              state.resultMap.selectedNodeID == active.id,
              let backend = modelProvider as? BackendModelProvider else {
            state.storedCulvertProfile.invalidate()
            return
        }
        let timeline = state.resultMap.selectedTimeline
        let profileIndex = timeline?.currentID ?? active.profileIndex ?? 0
        let workflowIdentity = mapSourceWorkflowIdentity(mapID)
        do {
            let capture = try StoredCulvertProfileCapture(
                projectSessionID: projectSessionID,
                workflowIdentity: workflowIdentity,
                map: map,
                snapshot: snapshot,
                resultNodeID: active.id,
                profileIndex: profileIndex)
            let captureIdentity = capture.identity
            let contextIdentity = capture.sourceContextIdentity
            let provider = BackendMapResultCulvertProfileProvider(client: backend.client)
            state.storedCulvertProfile.configure(capture: capture, provider: provider,
                timeline: timeline,
                isCurrent: { [weak self, weak state] in
                    guard let self, let state,
                          self.isCurrentMapState(state, mapID: mapID),
                          self.mapSourceWorkflowIdentity(mapID) == workflowIdentity,
                          self.mapIdentityRequest(for: mapID) == map,
                          state.selectedSourceContextIdentity == contextIdentity,
                          state.resultSources.snapshot?.sources.contextToken == capture.resultOwner.contextToken,
                          state.resultMap.selectedNodeID == active.id else { return false }
                    return state.storedCulvertProfile.capture?.identity == captureIdentity
                })
        } catch {
            state.storedCulvertProfile.invalidate()
            errorMessage = L10n.text(error.localizedDescription)
        }
    }

    /// Captures the exact visible WindLayer child selected by this map's
    /// source-context picker. A BoundaryCondition parent, including its line
    /// payload, is never substituted for the Wind node.
    func configureWindVelocityParticles(mapID: UUID) async {
        guard let state = existingMapState(for: mapID) else { return }
        guard !isOpeningProject, !isClosingTab,
              let selectedContext = state.selectedSourceContextIdentity,
              let selectedRecord = state.sourceMapRenderRows.first(where: {
                  $0.contextIdentity == selectedContext && $0.payloadKind == "WindLayer"
                      && $0.isActiveAndVisible
              }) else {
            state.resultMap.setWindVelocityParticleSource(nil)
            return
        }
        let capturedSession = projectSessionID
        guard let mapIdentity = mapIdentityRequest(for: mapID),
              let workflowIdentity = mapSourceWorkflowIdentity(mapID, state: state,
                  projectSessionID: capturedSession) else {
            state.resultMap.setWindVelocityParticleSource(nil)
            return
        }
        let treeContext = sourceMapTreeContext(mapID)
        guard treeContext.resultSelectionError == nil,
              let resultSnapshot = state.resultSources.snapshot,
              !resultSnapshot.sources.contextToken.isEmpty,
              let directory = document?.directory else {
            state.resultMap.setWindVelocityParticleSource(nil)
            return
        }
        let expectedResultMap = MapResultChartMapRequest(
            projectPath: mapIdentity.projectPath, projectXml: mapIdentity.projectXml,
            projectXmlSHA: mapIdentity.projectXmlSHA, mapID: mapIdentity.mapID,
            mapIndex: mapIdentity.mapIndex, mapName: mapIdentity.mapName,
            mapType: mapIdentity.mapType,
            expectedVisualizationRevision: mapIdentity.expectedVisualizationRevision)
        guard resultSnapshot.map == expectedResultMap else {
            state.resultMap.setWindVelocityParticleSource(nil)
            return
        }

        do {
            let rows = try await sourceMapLayerRows(mapID, context: treeContext)
            guard !Task.isCancelled,
                  isCurrentMapState(state, mapID: mapID, projectSessionID: capturedSession),
                  mapIdentityRequest(for: mapID) == mapIdentity,
                  mapSourceWorkflowIdentity(mapID, state: state,
                    projectSessionID: capturedSession) == workflowIdentity,
                  sourceMapTreeContext(mapID) == treeContext,
                  state.selectedSourceContextIdentity == selectedContext,
                  state.resultSources.snapshot?.sources.contextToken == resultSnapshot.sources.contextToken,
                  let currentRecord = state.sourceMapRenderRows.first(where: {
                      $0.contextIdentity == selectedContext && $0.payloadKind == "WindLayer"
                          && $0.isActiveAndVisible
                  }), currentRecord == selectedRecord else {
                state.resultMap.setWindVelocityParticleSource(nil)
                return
            }
            let windNode = currentRecord.locator
            guard windNode.nodeType == "WindLayer",
                  windNode.parentResultNodeType == nil, windNode.parentResultAssetID == nil,
                  windNode.parentResultNodePath == nil, windNode.parentResultNodeName == nil,
                  windNode.parentResultRevision == nil,
                  let parentAsset = windNode.parentBoundaryConditionAssetID,
                  let parentPath = windNode.parentBoundaryConditionNodePath,
                  let parentName = windNode.parentBoundaryConditionNodeName,
                  let windPath = windNode.nodePath, parentPath.count + 1 == windPath.count,
                  Array(windPath.prefix(parentPath.count)) == parentPath,
                  let windAsset = windNode.assetID,
                  SourceFilePaths.canonical(URL(fileURLWithPath: windAsset))
                    == SourceFilePaths.canonical(URL(fileURLWithPath: parentAsset)) else {
                state.resultMap.setWindVelocityParticleSource(nil)
                return
            }
            let boundaryRows = rows.filter { row in
                guard let locator = row.node.sourceLocator else { return false }
                return locator.nodeType == "BoundaryCondition"
                    && locator.rootName == windNode.rootName
                    && locator.nodeName == parentName
                    && locator.nodePath == parentPath
                    && locator.assetID.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0)) }
                        == SourceFilePaths.canonical(URL(fileURLWithPath: parentAsset))
                    && locator.parentResultNodeType == nil
                    && locator.parentResultAssetID == nil
                    && locator.parentResultNodePath == nil
                    && locator.parentResultNodeName == nil
                    && locator.parentResultRevision == nil
                    && row.isChecked && row.isEffectivelyVisible
            }
            guard boundaryRows.count == 1,
                  let boundaryNode = boundaryRows[0].node.sourceLocator,
                  selectedRecord.locator == windNode,
                  windNode.rootName == boundaryNode.rootName,
                  windNode.parentBoundaryConditionAssetID == boundaryNode.assetID,
                  windNode.parentBoundaryConditionNodePath == boundaryNode.nodePath,
                  windNode.parentBoundaryConditionNodeName == boundaryNode.nodeName,
                  let boundarySourcePath = boundaryNode.associationAssetID ?? boundaryNode.assetID else {
                state.resultMap.setWindVelocityParticleSource(nil)
                return
            }
            let boundaryURL = try PlatformPaths.resolve(boundarySourcePath,
                relativeTo: directory, mappings: pathMappings)
            let canonicalBoundaryPath = SourceFilePaths.canonical(boundaryURL)
            guard SourceFilePaths.canonical(URL(fileURLWithPath: boundaryNode.assetID ?? ""))
                    == canonicalBoundaryPath else {
                throw BackendServiceError(code: "sourceChanged",
                    message: "The selected Wind source no longer matches its Boundary Condition file.")
            }
            let boundaryRevision = try await Self.mapSourceRevision(boundaryURL)
            guard !Task.isCancelled,
                  isCurrentMapState(state, mapID: mapID, projectSessionID: capturedSession),
                  mapIdentityRequest(for: mapID) == mapIdentity,
                  mapSourceWorkflowIdentity(mapID, state: state,
                    projectSessionID: capturedSession) == workflowIdentity,
                  sourceMapTreeContext(mapID) == treeContext,
                  state.selectedSourceContextIdentity == selectedContext,
                  state.resultSources.snapshot?.sources.contextToken == resultSnapshot.sources.contextToken,
                  state.sourceMapRenderRows.first(where: { $0.contextIdentity == selectedContext }) == currentRecord else {
                state.resultMap.setWindVelocityParticleSource(nil)
                return
            }
            let map = MapWindVelocityMapRequest(
                projectPath: mapIdentity.projectPath, projectXml: mapIdentity.projectXml,
                projectXmlSHA: mapIdentity.projectXmlSHA, mapID: mapIdentity.mapID,
                mapIndex: mapIdentity.mapIndex, mapName: mapIdentity.mapName,
                mapType: mapIdentity.mapType,
                expectedVisualizationRevision: mapIdentity.expectedVisualizationRevision,
                resultSelectionOverrides: treeContext.resultSelectionOverrides)
            let initialCapture = MapWindVelocityParticleSource(
                projectSessionID: capturedSession, mapWorkflowIdentity: workflowIdentity,
                map: map, contextToken: resultSnapshot.sources.contextToken,
                selectionIdentity: windNode.sourceIdentity, boundaryNode: boundaryNode,
                windNode: windNode, boundaryPath: canonicalBoundaryPath,
                boundaryRevision: boundaryRevision, profileIndex: 0, profileTime: nil)
            // A newly discovered Wind context starts at the source's default
            // first profile. If this exact Wind source is already active in
            // the native velocity session, retain its selected profile/time
            // across a tree/context recapture instead of resetting to zero.
            let activeProfile = state.resultMap.selectedWindProfile(for: initialCapture)
            let capture = MapWindVelocityParticleSource(
                projectSessionID: capturedSession, mapWorkflowIdentity: workflowIdentity,
                map: map, contextToken: resultSnapshot.sources.contextToken,
                selectionIdentity: windNode.sourceIdentity, boundaryNode: boundaryNode,
                windNode: windNode, boundaryPath: canonicalBoundaryPath,
                boundaryRevision: boundaryRevision,
                profileIndex: activeProfile?.index ?? initialCapture.profileIndex,
                profileTime: activeProfile?.time)
            configureMapResultRendering(mapID)
            state.resultMap.setWindVelocityParticleSource(capture)
        } catch is CancellationError {
            state.resultMap.setWindVelocityParticleSource(nil)
        } catch {
            state.resultMap.setWindVelocityParticleSource(nil)
            if projectSessionID == capturedSession { errorMessage = L10n.text(error.localizedDescription) }
        }
    }

    /// Builds a style editor for one exact persisted Terrain or N-Value row.
    /// All owner arrays come from this map's current source tree, including
    /// unchecked focused owners used by the retained Matching Layers logic.
    /// The source SHA is read away from the main actor and refreshed after each
    /// accepted visualization write.
    func makeAssociatedRasterStyleSession(node: LayerTreeNode, mapID: UUID) async throws
        -> AssociatedRasterStyleSession {
        guard !isOpeningProject, !isClosingTab,
              let backend = modelProvider as? BackendModelProvider,
              let requestedLocator = node.sourceLocator,
              ["Terrain", "NValue"].contains(requestedLocator.nodeType),
              let initialMap = mapIdentityRequest(for: mapID) else {
            throw AssociatedRasterStyleError.incompleteIdentity
        }
        let projectSession = projectSessionID
        let initialSourceWorkflow = mapSourceWorkflowIdentity(mapID)
        let initialRows = try await sourceMapLayerRows(mapID)
        guard projectSessionID == projectSession,
              mapSourceWorkflowIdentity(mapID) == initialSourceWorkflow,
              mapIdentityRequest(for: mapID) == initialMap,
              let row = initialRows.first(where: { $0.node.sourceLocator == requestedLocator }),
              let locator = row.node.sourceLocator,
              row.isGeometryAssociationContext,
              let directory = document?.directory,
              let rawPath = locator.associationAssetID ?? locator.assetID,
              !rawPath.isEmpty else {
            throw AssociatedRasterStyleError.staleContext
        }
        let sourceURL = try PlatformPaths.resolve(rawPath, relativeTo: directory, mappings: pathMappings)
        let expectedSection: ProjectSection = locator.nodeType == "Terrain" ? .terrains : .surfaceLayers
        guard assets.contains(where: {
            $0.section == expectedSection && $0.isModelFile
                && SourceFilePaths.canonical($0.url) == SourceFilePaths.canonical(sourceURL)
        }) else { throw AssociatedRasterStyleError.incompleteIdentity }
        let sourcePath = SourceFilePaths.canonical(sourceURL)
        let sourceRevision = try await Self.mapSourceRevision(sourceURL)
        guard projectSessionID == projectSession,
              mapSourceWorkflowIdentity(mapID) == initialSourceWorkflow,
              mapIdentityRequest(for: mapID) == initialMap else {
            throw AssociatedRasterStyleError.staleContext
        }
        let owners = try associatedRasterStyleOwners(locator: locator, map: initialMap,
            rows: initialRows, resultSnapshot: mapState(for: mapID).resultSources.snapshot)
        let workflowIdentity = associatedRasterStyleOwnerIdentity(
            projectSessionID: projectSession, map: initialMap, node: locator,
            sourcePath: sourcePath, owners: owners)
        let initialContext = try AssociatedRasterStyleContext(projectSessionID: projectSession,
            mapWorkflowIdentity: workflowIdentity, map: initialMap, node: locator,
            sourcePath: sourcePath, sourceRevision: sourceRevision,
            geometryNodes: owners.geometryNodes, planNodes: owners.planNodes,
            resultOwner: owners.resultOwner)
        let provider = BackendAssociatedRasterStyleProvider(client: backend.client,
            isCurrent: { [weak self] context in
                guard let self, self.projectSessionID == context.projectSessionID,
                      self.mapIdentityRequest(for: mapID) == context.map,
                      self.associatedRasterStyleOwnerIdentity(projectSessionID: context.projectSessionID,
                        map: context.map, node: context.node, sourcePath: context.sourcePath,
                        owners: self.ownersFor(context))
                            == context.mapWorkflowIdentity else { return false }
                let state = self.mapState(for: mapID)
                guard state.resultSourceIdentity == self.mapSourceWorkflowIdentity(mapID),
                      state.sourceMapLayerRows.contains(where: {
                          $0.node.sourceLocator == context.node && $0.isGeometryAssociationContext
                      }),
                      let currentOwners = try? self.associatedRasterStyleOwners(locator: context.node,
                          map: context.map, rows: state.sourceMapLayerRows,
                          resultSnapshot: state.resultSources.snapshot) else { return false }
                return currentOwners == self.ownersFor(context)
            },
            refreshContext: { [weak self] context in
                guard let self, self.projectSessionID == projectSession,
                      let beforeRefreshMap = self.mapIdentityRequest(for: mapID),
                      self.sameSavedMapOwner(beforeRefreshMap, as: initialMap) else { return nil }
                // The style mutation changes .vis and therefore its result
                // context token. Rebuild the map tree and owner captures before
                // allowing another edit in this style session.
                await self.configureMapResultSources(mapID)
                guard self.projectSessionID == projectSession,
                      let currentMap = self.mapIdentityRequest(for: mapID),
                      self.sameSavedMapOwner(currentMap, as: initialMap) else { return nil }
                let rows = try await self.sourceMapLayerRows(mapID)
                guard self.projectSessionID == projectSession,
                      self.mapIdentityRequest(for: mapID) == currentMap else { return nil }
                let refreshedRows = rows.filter { row in
                    guard row.isGeometryAssociationContext,
                          let currentLocator = row.node.sourceLocator else { return false }
                    return self.sameRasterStyleLocatorOrMaterializationSuccessor(
                        from: context.node, to: currentLocator)
                }
                guard refreshedRows.count == 1,
                      let refreshedRow = refreshedRows.first,
                      let refreshedLocator = refreshedRow.node.sourceLocator,
                      let currentDirectory = self.document?.directory else { return nil }
                let refreshedRawPath = refreshedLocator.associationAssetID ?? refreshedLocator.assetID
                guard let refreshedRawPath else { return nil }
                let refreshedURL = try PlatformPaths.resolve(refreshedRawPath,
                    relativeTo: currentDirectory, mappings: self.pathMappings)
                let refreshedPath = SourceFilePaths.canonical(refreshedURL)
                guard refreshedPath == sourcePath else { return nil }
                let refreshedRevision = try await Self.mapSourceRevision(refreshedURL)
                guard self.projectSessionID == projectSession,
                      self.mapIdentityRequest(for: mapID) == currentMap,
                      self.sameRasterStyleLocatorOrMaterializationSuccessor(
                        from: context.node, to: refreshedLocator) else { return nil }
                let refreshedOwners = try self.associatedRasterStyleOwners(locator: refreshedLocator,
                    map: currentMap, rows: rows,
                    resultSnapshot: self.mapState(for: mapID).resultSources.snapshot)
                let refreshedWorkflowIdentity = self.associatedRasterStyleOwnerIdentity(
                    projectSessionID: projectSession, map: currentMap,
                    node: refreshedLocator, sourcePath: refreshedPath, owners: refreshedOwners)
                let originalMaterializationIdentity = self.associatedRasterStyleOwnerIdentity(
                    projectSessionID: context.projectSessionID, map: context.map,
                    node: context.node, sourcePath: context.sourcePath,
                    owners: self.ownersFor(context), ignoringMaterializedTargetPaths: true)
                let refreshedMaterializationIdentity = self.associatedRasterStyleOwnerIdentity(
                    projectSessionID: projectSession, map: currentMap,
                    node: refreshedLocator, sourcePath: refreshedPath,
                    owners: refreshedOwners, ignoringMaterializedTargetPaths: true)
                guard originalMaterializationIdentity == refreshedMaterializationIdentity else { return nil }
                return try AssociatedRasterStyleContext(projectSessionID: projectSession,
                    mapWorkflowIdentity: refreshedWorkflowIdentity, map: currentMap,
                    node: refreshedLocator, sourcePath: refreshedPath,
                    sourceRevision: refreshedRevision,
                    geometryNodes: refreshedOwners.geometryNodes,
                    planNodes: refreshedOwners.planNodes,
                    resultOwner: refreshedOwners.resultOwner)
            },
            beginMutation: { [weak self] in self?.beginAssociatedRasterStyleMutation() ?? false },
            endMutation: { [weak self] in
                guard let self else { return }
                self.endAssociatedRasterStyleMutation()
            },
            acceptMapChange: { [weak self] oldRevision, newRevision in
                guard let self else { throw ProjectFileError.modifiedExternally }
                try self.acceptAssociatedRasterStyleMapChange(oldRevision: oldRevision,
                    newRevision: newRevision)
            })
        return AssociatedRasterStyleSession(context: initialContext, provider: provider)
    }

    private func associatedRasterStyleOwners(locator: CatalogTreeNodeLocator,
                                              map: MapTreeMapIdentity,
                                              rows: [SourceMapLayerRow],
                                              resultSnapshot: MapResultSourcesSnapshot?) throws
        -> AssociatedRasterStyleOwners {
        func canonical(_ path: String?) -> String? {
            path.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0)) }
        }
        let allGeometryNodes = rows.compactMap { $0.node.sourceLocator }.filter {
            $0.nodeType == "Geometry" && $0.nodePath?.isEmpty == false
                && $0.assetID?.isEmpty == false && !hasResultParent($0)
        }
        let focusedGeometryNodes = allGeometryNodes.filter { $0.rootName == "Focused Geometries" }
        let focusedPlanNodes = rows.compactMap { $0.node.sourceLocator }.filter {
            $0.isFocusedPlanOwner
                && $0.assetID?.hasPrefix("/") == true && !$0.nodeName.isEmpty
        }
        let resultOwner = try resultGeometryOwner(locator: locator, snapshot: resultSnapshot)

        let geometryNodes: [CatalogTreeNodeLocator]
        if resultOwner != nil {
            geometryNodes = []
        } else if hasGeometryParent(locator) {
            guard let path = locator.parentGeometryNodePath,
                  let name = locator.parentGeometryNodeName,
                  let asset = locator.parentGeometryAssetID,
                  let owner = allGeometryNodes.first(where: {
                      $0.nodePath == path && $0.nodeName == name
                          && canonical($0.assetID) == canonical(asset)
                  }) else {
                throw AssociatedRasterStyleError.incompleteIdentity
            }
            geometryNodes = [owner]
        } else if map.mapType == "Geometry", locator.rootName == "Matching Layers" {
            guard focusedGeometryNodes.count >= 2 else {
                throw AssociatedRasterStyleError.incompleteIdentity
            }
            geometryNodes = focusedGeometryNodes
        } else {
            geometryNodes = []
        }

        let planNodes: [CatalogTreeNodeLocator]
        if resultOwner != nil {
            // A Result-owned row may also carry its outer Plan annotation.
            // The exact selected Result owner resolves that Plan dependency;
            // do not demand a Plan-map locator for a Result row in a Geometry
            // map or widen the request to unrelated focused Plans.
            planNodes = []
        } else if hasPlanParent(locator) {
            guard map.mapType == "Plan",
                  let path = locator.parentPlanNodePath,
                  let name = locator.parentPlanNodeName,
                  let asset = locator.parentPlanAssetID,
                  let owner = focusedPlanNodes.first(where: {
                      $0.nodePath == path && $0.nodeName == name
                          && canonical($0.assetID) == canonical(asset)
                  }) else {
                throw AssociatedRasterStyleError.incompleteIdentity
            }
            planNodes = [owner]
        } else if map.mapType == "Plan", locator.rootName == "Matching Layers" {
            guard focusedPlanNodes.count >= 2 else {
                throw AssociatedRasterStyleError.incompleteIdentity
            }
            planNodes = focusedPlanNodes
        } else {
            planNodes = []
        }

        return AssociatedRasterStyleOwners(geometryNodes: geometryNodes,
            planNodes: planNodes, resultOwner: resultOwner)
    }

    private func associatedRasterStyleOwnerIdentity(projectSessionID: UUID,
                                                    map: MapTreeMapIdentity,
                                                    node: CatalogTreeNodeLocator,
                                                    sourcePath: String,
                                                    owners: AssociatedRasterStyleOwners,
                                                    ignoringMaterializedTargetPaths: Bool = false) -> String {
        // The .vis revision and chart context token rotate after an accepted
        // write. This stable token identifies the same map row/source owners;
        // currentness still compares the full live MapTreeMapIdentity and
        // Result context separately.
        let resultOwner: String
        if let owner = owners.resultOwner {
            let overrides = (owner.selectionOverrides ?? []).map { item in
                [item.nodeIdentity, String(item.selectionIndex), item.mode.rawValue,
                 item.resultPath.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0)) } ?? "",
                 item.resultRevision?.uppercased() ?? ""].joined(separator: ":")
            }.joined(separator: "\u{1e}")
            resultOwner = [owner.resultNode.sourceIdentity, String(owner.selectionIndex),
                owner.selectedResultPath, owner.selectedResultRevision, overrides].joined(separator: "|")
        } else {
            resultOwner = ""
        }
        let nodeIdentity: String
        if ignoringMaterializedTargetPaths {
            // Callers reach this only after sameRasterStyleLocatorOrMaterializationSuccessor
            // has validated the exact nil-to-path transition and, for Result-owned rows,
            // the direct Result → Geometry → target ancestry. Do not use this form for
            // currentness checks or to accept arbitrary owner/path changes.
            var stableNode = node
            stableNode.nodePath = nil
            stableNode.parentGeometryNodePath = nil
            nodeIdentity = stableNode.sourceIdentity
        } else {
            nodeIdentity = node.sourceIdentity
        }
        return [projectSessionID.uuidString, map.mapID, String(map.mapIndex), map.mapName,
            map.mapType, SourceFilePaths.canonical(URL(fileURLWithPath: map.projectPath)),
            nodeIdentity, SourceFilePaths.canonical(URL(fileURLWithPath: sourcePath)),
            owners.geometryNodes.map(\.sourceIdentity).joined(separator: "\n"),
            owners.planNodes.map(\.sourceIdentity).joined(separator: "\n"), resultOwner]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    private func sameRasterStyleLocatorOrMaterializationSuccessor(
        from captured: CatalogTreeNodeLocator, to current: CatalogTreeNodeLocator) -> Bool {
        if captured == current { return true }
        guard captured.nodePath == nil, current.nodePath?.isEmpty == false else { return false }

        let materializedGeometryParent = captured.parentGeometryNodePath == nil
            && current.parentGeometryNodePath?.isEmpty == false
        var capturedNormalized = captured
        var currentNormalized = current
        capturedNormalized.nodePath = nil
        currentNormalized.nodePath = nil
        if materializedGeometryParent {
            capturedNormalized.parentGeometryNodePath = nil
            currentNormalized.parentGeometryNodePath = nil
        }
        guard capturedNormalized == currentNormalized else { return false }
        guard materializedGeometryParent else { return true }

        guard let geometryPath = current.parentGeometryNodePath,
              let resultPath = current.parentResultNodePath,
              !resultPath.isEmpty,
              let resultType = current.parentResultNodeType,
              resultType == "Result" || resultType == "MultiResult",
              let resultAsset = current.parentResultAssetID, resultAsset.hasPrefix("/"),
              let resultName = current.parentResultNodeName, !resultName.isEmpty,
              let resultRevision = current.parentResultRevision,
              resultRevision.count == 64, resultRevision == resultRevision.uppercased(),
              resultRevision.allSatisfy(\.isHexDigit),
              let geometryAsset = current.parentGeometryAssetID, geometryAsset.hasPrefix("/"),
              let geometryName = current.parentGeometryNodeName, !geometryName.isEmpty,
              geometryPath.allSatisfy({ $0 >= 0 }), resultPath.allSatisfy({ $0 >= 0 }),
              geometryPath.count == resultPath.count + 1,
              Array(geometryPath.prefix(resultPath.count)) == resultPath,
              let leafPath = current.nodePath,
              leafPath.allSatisfy({ $0 >= 0 }),
              leafPath.count == geometryPath.count + 1,
              Array(leafPath.prefix(geometryPath.count)) == geometryPath else { return false }
        return true
    }

    private func ownersFor(_ context: AssociatedRasterStyleContext) -> AssociatedRasterStyleOwners {
        AssociatedRasterStyleOwners(geometryNodes: context.geometryNodes,
            planNodes: context.planNodes, resultOwner: context.resultOwner)
    }

    /// Geometry children are resolved from this selected saved map's actual
    /// tree. Their style contexts and HDF paths stay tied to the exact Geometry
    /// owner in this map; no editor-preview or last-active-map state is used.
    private func configureProjectGeometryMap(_ mapID: UUID,
                                             map: MapTreeMapIdentity,
                                             identity: String,
                                             rows: [SourceMapLayerRow]) async {
        let expectedSession = projectSessionID
        guard let state = existingMapState(for: mapID),
              isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
              mapIdentityRequest(for: mapID) == map,
              mapSourceWorkflowIdentity(mapID, state: state, projectSessionID: expectedSession) == identity else { return }
        state.projectGeometryMap.invalidateIfWorkflowChanged(identity)
        guard ["Project", "Buildable", "Geometry", "Plan"].contains(map.mapType) else {
            state.projectGeometryMap.reportConfigurationError(
                "The selected map type does not provide saved Geometry layer rendering in this native workflow.")
            return
        }
        guard let directory = document?.directory,
              let backend = modelProvider as? BackendModelProvider else {
            state.projectGeometryMap.invalidate()
            return
        }
        let nodes = rows.map(\.node)
        var captures: [ProjectGeometryMapCapture] = []
        var diagnostics: [String] = []
        // RebuildMatchingLayers uses the map's complete Focused Plans
        // collection. A Plan's own checkbox controls that Plan's children,
        // but does not remove it from the shared-source relationship.
        let focusedPlanNodes = nodes.compactMap { node -> CatalogTreeNodeLocator? in
            guard let locator = node.sourceLocator,
                  locator.isFocusedPlanOwner,
                  locator.assetID?.hasPrefix("/") == true,
                  !locator.nodeName.isEmpty else { return nil }
            return locator
        }
        let resultSnapshot = state.resultSources.snapshot
        for sourceRow in rows {
            let row = sourceRow.node
            guard let locator = row.sourceLocator, locator.nodeType == "Geometry" else { continue }
            guard sourceRow.isEffectivelyVisible else { continue }
            // Sparse saved trees retain implicit, unchecked Geometry defaults
            // without a serialized path. They are not active source contexts.
            if locator.nodePath == nil, row.checked == .unchecked { continue }
            guard
                  let assetPath = row.assetID ?? locator.assetID,
                  !assetPath.isEmpty,
                  !row.name.isEmpty else {
                diagnostics.append("The selected Geometry map row has no absolute source asset identity.")
                continue
            }
            do {
                let resultOwner = try resultGeometryOwner(locator: locator, snapshot: resultSnapshot)
                let planNodes: [CatalogTreeNodeLocator]
                if resultOwner != nil || map.mapType != "Plan" {
                    planNodes = []
                } else if locator.rootName == "Focused Plans",
                          hasPlanParent(locator),
                          let parentAsset = locator.parentPlanAssetID,
                          let parentName = locator.parentPlanNodeName,
                          let owner = focusedPlanNodes.first(where: {
                              $0.nodePath == locator.parentPlanNodePath
                                  && $0.nodeName == parentName
                                  && canonicalSourcePath($0.assetID) == canonicalSourcePath(parentAsset)
                          }) {
                    planNodes = [owner]
                } else if locator.rootName == "Matching Layers", !hasPlanParent(locator),
                          focusedPlanNodes.count >= 2 {
                    // Source Matching Layers contains relationships common to
                    // every focused Plan, independent of their checkboxes.
                    planNodes = focusedPlanNodes
                } else {
                    throw BackendServiceError(code: "sourceChanged",
                        message: "The selected Plan Geometry row has no exact focused Plan owner.")
                }
                let sourceURL: URL
                if let resultOwner {
                    sourceURL = URL(fileURLWithPath: resultOwner.selectedResultPath)
                } else {
                    sourceURL = try PlatformPaths.resolve(assetPath, relativeTo: directory, mappings: pathMappings)
                }
                captures.append(try ProjectGeometryMapCapture(
                    projectSessionID: projectSessionID,
                    mapID: mapID,
                    mapWorkflowIdentity: identity,
                    map: map,
                    geometryNode: locator,
                    geometryAssetPath: sourceURL.standardizedFileURL.path,
                    geometryName: row.name,
                    resultOwner: resultOwner,
                    planNodes: planNodes))
            } catch {
                diagnostics.append(error.localizedDescription)
            }
        }
        let provider = BackendProjectGeometryMapProvider(client: backend.client, isCurrent: { [weak self, weak state] in
            guard let self, let state else { return false }
            return self.isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession)
                && self.mapSourceWorkflowIdentity(mapID, state: state,
                    projectSessionID: expectedSession) == identity
        })
        await state.projectGeometryMap.configure(
            map: map,
            workflowIdentity: identity,
            captures: captures,
            provider: provider,
            preflightDiagnostics: diagnostics,
            isCurrent: { [weak self, weak state] in
                guard let self, let state else { return false }
                return self.isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession)
                    && self.mapSourceWorkflowIdentity(mapID, state: state,
                        projectSessionID: expectedSession) == identity
            })
    }

    private func configureAssociatedMapLayers(_ mapID: UUID,
                                              map: MapTreeMapIdentity,
                                              identity: String,
                                              rows: [SourceMapLayerRow]) async {
        let expectedSession = projectSessionID
        guard let state = existingMapState(for: mapID),
              isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
              mapIdentityRequest(for: mapID) == map,
              mapSourceWorkflowIdentity(mapID, state: state, projectSessionID: expectedSession) == identity else { return }
        guard ["Project", "Buildable", "Geometry", "Plan"].contains(map.mapType),
              let directory = document?.directory,
              let backend = modelProvider as? BackendModelProvider else {
            state.associatedMapLayers.invalidate()
            return
        }
        var diagnostics: [String] = []
        let geometryNodes = rows.compactMap { row -> CatalogTreeNodeLocator? in
            guard let locator = row.node.sourceLocator,
                  locator.nodeType == "Geometry",
                  locator.nodePath?.isEmpty == false,
                  locator.assetID?.isEmpty == false else { return nil }
            return locator
        }
        let focusedPlanNodes = rows.compactMap { row -> CatalogTreeNodeLocator? in
            guard let locator = row.node.sourceLocator,
                  locator.isFocusedPlanOwner,
                  locator.assetID?.hasPrefix("/") == true,
                  !locator.nodeName.isEmpty else { return nil }
            return locator
        }
        let associationRows = rows.filter {
            $0.isGeometryAssociationContext
        }
        var captures: [AssociatedMapLayerCapture] = []
        for row in associationRows {
            // Unchecked/ancestor-hidden associations remain in the exact tree
            // and can be enabled there. They do not need pixel requests until
            // the source tree makes the row effectively visible.
            guard row.isEffectivelyVisible else { continue }
            guard let locator = row.node.sourceLocator,
                  locator.associationKind == locator.nodeType,
                  let rawAssetPath = locator.associationAssetID,
                  !rawAssetPath.isEmpty,
                  let kind = AssociatedMapLayerCapture.supportedKind(locator.associationKind) else {
                diagnostics.append("The selected associated map layer has no exact source identity.")
                continue
            }
            do {
                let planNodes: [CatalogTreeNodeLocator]
                let resultOwners: [MapResultGeometryOwner]
                if hasPlanParent(locator) {
                    guard let owner = focusedPlanNodes.first(where: {
                        $0.nodePath == locator.parentPlanNodePath
                            && $0.nodeName == locator.parentPlanNodeName
                            && canonicalSourcePath($0.assetID) == canonicalSourcePath(locator.parentPlanAssetID)
                    }) else {
                        throw BackendServiceError(code: "sourceChanged", message: "The associated layer's exact focused Plan is not active in this map.")
                    }
                    planNodes = [owner]
                } else if map.mapType == "Plan" && locator.rootName == "Matching Layers" {
                    guard !hasPlanParent(locator), focusedPlanNodes.count >= 2 else {
                        throw BackendServiceError(code: "sourceChanged", message: "The shared Plan layer does not match the complete focused Plan set.")
                    }
                    planNodes = focusedPlanNodes
                } else if map.mapType == "Plan" {
                    throw BackendServiceError(code: "sourceChanged", message: "The Plan-associated layer has no exact focused Plan owner.")
                } else {
                    planNodes = []
                }

                if hasResultParent(locator) {
                    guard let resultOwner = try resultGeometryOwner(locator: locator,
                                                                    snapshot: state.resultSources.snapshot),
                          rows.contains(where: { $0.node.sourceLocator == resultOwner.resultNode
                              && $0.isEffectivelyVisible }) else {
                        throw BackendServiceError(code: "sourceChanged", message: "The associated layer's exact slot-zero Result is not active in this map.")
                    }
                    resultOwners = [resultOwner]
                } else {
                    resultOwners = []
                }

                let exactGeometryNodes: [CatalogTreeNodeLocator]
                if hasGeometryParent(locator) {
                    guard let parentGeometryPath = locator.parentGeometryNodePath,
                          let parentGeometryName = locator.parentGeometryNodeName,
                          let parentGeometryAsset = locator.parentGeometryAssetID else {
                        throw BackendServiceError(code: "sourceChanged", message: "The associated layer's Geometry owner identity is incomplete.")
                    }
                    guard let parentGeometry = geometryNodes.first(where: {
                        $0.nodePath == parentGeometryPath
                            && $0.nodeName == parentGeometryName
                            && canonicalSourcePath($0.assetID) == canonicalSourcePath(parentGeometryAsset)
                    }) else {
                        throw BackendServiceError(code: "sourceChanged", message: "The associated layer's exact Geometry owner is not active in this map.")
                    }
                    exactGeometryNodes = [parentGeometry]
                } else if map.mapType != "Plan" && resultOwners.isEmpty {
                    exactGeometryNodes = geometryNodes
                } else {
                    exactGeometryNodes = []
                }

                guard !exactGeometryNodes.isEmpty || !planNodes.isEmpty || !resultOwners.isEmpty else {
                    throw BackendServiceError(code: "sourceChanged", message: "The associated map layer has no active exact Geometry, Plan, or Result owner.")
                }
                let assetURL = try PlatformPaths.resolve(rawAssetPath, relativeTo: directory, mappings: pathMappings)
                let expectedSection: ProjectSection = switch kind {
                case .terrain: .terrains
                case .nValue, .classification: .surfaceLayers
                }
                guard let asset = assets.first(where: {
                    $0.section == expectedSection && $0.isModelFile
                        && SourceFilePaths.canonical($0.url) == SourceFilePaths.canonical(assetURL)
                }) else {
                    throw BackendServiceError(code: "sourceChanged", message: "The associated map source is not an asset in the current project.")
                }
                captures.append(try AssociatedMapLayerCapture(
                    projectSessionID: projectSessionID,
                    mapID: mapID,
                    mapWorkflowIdentity: identity,
                    map: map,
                    geometryNodes: exactGeometryNodes,
                    planNodes: planNodes,
                    resultOwners: resultOwners,
                    associationNode: locator,
                    assetPath: SourceFilePaths.canonical(asset.url),
                    isChecked: row.isChecked,
                    effectiveVisible: row.isEffectivelyVisible))
            } catch {
                diagnostics.append(error.localizedDescription)
            }
        }
        let provider = BackendAssociatedMapLayerProvider(client: backend.client,
            isCurrent: { [weak self, weak state] in
                guard let self, let state else { return false }
                return self.isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession)
                    && self.mapSourceWorkflowIdentity(mapID, state: state,
                        projectSessionID: expectedSession) == identity
            })
        await state.associatedMapLayers.configure(
            map: map,
            workflowIdentity: identity,
            captures: captures,
            provider: provider,
            isCurrent: { [weak self, weak state] in
                guard let self, let state else { return false }
                return self.isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession)
                    && self.mapSourceWorkflowIdentity(mapID, state: state,
                        projectSessionID: expectedSession) == identity
            },
            preflightDiagnostics: diagnostics,
            rasterRuntimeOptions: state.associatedRasterRuntimeOptions.filter { option in
                captures.contains { option.matches($0) }
            })
    }

    func associatedRasterTileOutlines(mapID: UUID, locator: CatalogTreeNodeLocator,
        assetPath: String) -> Bool {
        guard let state = existingMapState(for: mapID) else { return false }
        let path = SourceFilePaths.canonical(URL(fileURLWithPath: assetPath))
        return state.associatedRasterRuntimeOptions.contains {
            $0.locator == locator && SourceFilePaths.canonical(URL(fileURLWithPath: $0.assetPath)) == path
                && $0.plotRasterTileOutlines
        }
    }
    func setAssociatedRasterTileOutlines(_ enabled: Bool, mapID: UUID,
        locator: CatalogTreeNodeLocator, assetPath: String) {
        guard !isRunningPlanCompute, let state = existingMapState(for: mapID),
              state.sourceMapRenderRows.contains(where: {
                $0.locator == locator && $0.isActiveAndVisible
                    && ($0.payloadKind == "Terrain" || $0.payloadKind == "NValue")
              }),
              let capture = state.associatedMapLayers.entries.first(where: {
                $0.capture.associationNode == locator
                    && $0.capture.assetPath == SourceFilePaths.canonical(URL(fileURLWithPath: assetPath))
              })?.capture, capture.isChecked, capture.effectiveVisible else { return }
        state.associatedRasterRuntimeOptions.removeAll {
            $0.locator == locator && SourceFilePaths.canonical(URL(fileURLWithPath: $0.assetPath)) == capture.assetPath
        }
        if enabled {
            state.associatedRasterRuntimeOptions.append(.init(locator: locator,
                assetPath: capture.assetPath, plotRasterTileOutlines: true))
        }
        state.associatedMapLayers.setRasterRuntimeOptions(state.associatedRasterRuntimeOptions)
        let sessionID = projectSessionID
        Task { [weak self, weak state] in
            guard let self, let state,
                  self.isCurrentMapState(state, mapID: mapID, projectSessionID: sessionID) else { return }
            await state.associatedMapLayers.refresh()
        }
    }

    private func hasPlanParent(_ locator: CatalogTreeNodeLocator) -> Bool {
        locator.parentPlanAssetID != nil || locator.parentPlanNodePath != nil
            || locator.parentPlanNodeName != nil
    }

    private func hasResultParent(_ locator: CatalogTreeNodeLocator) -> Bool {
        locator.parentResultNodeType != nil || locator.parentResultAssetID != nil
            || locator.parentResultNodePath != nil || locator.parentResultNodeName != nil
            || locator.parentResultRevision != nil
    }

    private func hasGeometryParent(_ locator: CatalogTreeNodeLocator) -> Bool {
        locator.parentGeometryAssetID != nil || locator.parentGeometryNodePath != nil
            || locator.parentGeometryNodeName != nil
    }

    private struct SelectedResultTreeOwner {
        let node: CatalogTreeNodeLocator
        let contextToken: String
        let overrides: [MapResultSelectionOverride]
        let selectedPath: String
        let selectedRevision: String
    }

    private func selectedResultTreeOwner(for locator: CatalogTreeNodeLocator,
                                         snapshot: MapResultSourcesSnapshot?) throws -> SelectedResultTreeOwner? {
        let hasResultOwner = locator.parentResultNodeType != nil || locator.parentResultAssetID != nil
            || locator.parentResultNodePath != nil || locator.parentResultNodeName != nil
            || locator.parentResultRevision != nil
        guard hasResultOwner else { return nil }
        guard let snapshot,
              let type = locator.parentResultNodeType,
              let nodePath = locator.parentResultNodePath,
              let nodeName = locator.parentResultNodeName,
              let resultPath = locator.parentResultAssetID,
              let revision = locator.parentResultRevision,
              let active = snapshot.sources.activeNodes.first(where: {
                  $0.node.nodeType == type && $0.node.nodePath == nodePath
                      && $0.node.nodeName == nodeName && $0.node.rootName == locator.rootName
              }),
              let slot = active.selections.first(where: { $0.selectionIndex == 0 }),
              let selected = slot.selectedResult,
              SourceFilePaths.canonical(URL(fileURLWithPath: resultPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: selected.resultPath)),
              revision.caseInsensitiveCompare(selected.revision) == .orderedSame else {
            throw BackendServiceError(code: "sourceChanged", message: "The selected Result child does not match the active Result source and profile slot.")
        }
        return SelectedResultTreeOwner(node: active.node, contextToken: snapshot.sources.contextToken,
            overrides: snapshot.selectionOverrides, selectedPath: selected.resultPath,
            selectedRevision: selected.revision)
    }

    private func resultGeometryOwner(locator: CatalogTreeNodeLocator,
                                     snapshot: MapResultSourcesSnapshot?) throws -> MapResultGeometryOwner? {
        guard let owner = try selectedResultTreeOwner(for: locator, snapshot: snapshot) else { return nil }
        return try MapResultGeometryOwner(resultNode: owner.node, contextToken: owner.contextToken,
            selectionOverrides: owner.overrides, selectionIndex: 0,
            selectedResultPath: owner.selectedPath, selectedResultRevision: owner.selectedRevision)
    }

    private func configureBoundaryMap(_ mapID: UUID, map: MapTreeMapIdentity,
                                      identity: String, rows: [SourceMapLayerRow]) async {
        let expectedSession = projectSessionID
        guard let state = existingMapState(for: mapID),
              isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
              mapIdentityRequest(for: mapID) == map,
              mapSourceWorkflowIdentity(mapID, state: state, projectSessionID: expectedSession) == identity else { return }
        state.boundaryCaptureGeneration &+= 1
        let captureGeneration = state.boundaryCaptureGeneration
        guard ["Project", "Buildable", "Plan", "Geometry"].contains(map.mapType),
              modelProvider is BackendModelProvider else {
            state.boundaryMap.invalidate()
            return
        }
        let resultSnapshot = state.resultSources.snapshot
        let focusedPlanNodes = rows.compactMap { row -> CatalogTreeNodeLocator? in
            guard let locator = row.node.sourceLocator,
                  locator.isFocusedPlanOwner,
                  locator.assetID?.hasPrefix("/") == true, !locator.nodeName.isEmpty else { return nil }
            return locator
        }
        var captures: [BoundaryMapCapture] = []
        // RasMap paints source tree contexts in reverse tree order. Preserve
        // each Boundary file's internal line order while reversing only the
        // owning source rows here.
        for row in rows.reversed() where row.node.sourceLocator?.nodeType == "BoundaryCondition" {
            guard let locator = row.node.sourceLocator else { continue }
            let hasResultOwner = locator.parentResultNodeType != nil
                || locator.parentResultAssetID != nil
                || locator.parentResultNodePath != nil
                || locator.parentResultNodeName != nil
                || locator.parentResultRevision != nil
            // Embedded Boundary children are rebuilt from the selected
            // Result slot. A hidden Result/MultiResult child is not a map
            // source and must not be resolved against the current slot.
            if hasResultOwner && !row.isEffectivelyVisible { continue }
            // Sparse map defaults can expose an implicit unchecked child
            // without a serialized locator path. It is not an active context;
            // avoid turning that source default into a false configuration
            // warning. A visible row without identity still fails below.
            if locator.nodePath == nil && !row.isEffectivelyVisible { continue }
            do {
                let resultOwner = try selectedResultTreeOwner(for: locator, snapshot: resultSnapshot).map {
                    try MapResultOwnerSelection(resultNode: $0.node, contextToken: $0.contextToken,
                        selectionOverrides: $0.overrides, selectionIndex: 0,
                        selectedResultPath: $0.selectedPath, selectedResultRevision: $0.selectedRevision)
                }
                if resultOwner == nil, map.mapType == "Plan",
                   locator.rootName == "Matching Layers" {
                    guard locator.associationKind == "BoundaryCondition",
                          locator.parentPlanAssetID == nil,
                          locator.parentPlanNodePath == nil,
                          locator.parentPlanNodeName == nil,
                          focusedPlanNodes.count >= 2 else {
                        throw BackendServiceError(code: "sourceChanged",
                            message: "The shared Plan Boundary Condition does not match the complete focused Plan set.")
                    }
                }
                let rawPath: String
                let revision: String
                if let resultOwner {
                    rawPath = resultOwner.selectedResultPath
                    revision = resultOwner.selectedResultRevision
                } else {
                    guard let sourcePath = locator.associationAssetID ?? locator.assetID else {
                        throw BackendServiceError(code: "sourceChanged", message: "The selected Boundary Condition row has no exact source file identity.")
                    }
                    guard let directory = document?.directory else {
                        throw BackendServiceError(code: "sourceChanged", message: "Open the saved project before loading its Boundary Condition map.")
                    }
                    let sourceURL = try PlatformPaths.resolve(sourcePath, relativeTo: directory,
                        mappings: pathMappings)
                    rawPath = sourceURL.path
                    revision = try await Self.mapSourceRevision(sourceURL)
                    guard !Task.isCancelled,
                          isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
                          state.boundaryCaptureGeneration == captureGeneration,
                          mapSourceWorkflowIdentity(mapID, state: state,
                            projectSessionID: expectedSession) == identity,
                          mapIdentityRequest(for: mapID) == map else { return }
                }
                captures.append(try BoundaryMapCapture(projectSessionID: expectedSession,
                    mapWorkflowIdentity: identity, map: map, boundaryNode: locator,
                    sourcePath: rawPath, sourceRevision: revision, resultOwner: resultOwner,
                    isChecked: row.isChecked, effectiveVisible: row.isEffectivelyVisible))
            } catch {
                guard !Task.isCancelled,
                      isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
                      state.boundaryCaptureGeneration == captureGeneration,
                      mapSourceWorkflowIdentity(mapID, state: state,
                        projectSessionID: expectedSession) == identity,
                      mapIdentityRequest(for: mapID) == map else { return }
                errorMessage = L10n.text(error.localizedDescription)
            }
        }
        guard !Task.isCancelled,
              isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
              state.boundaryCaptureGeneration == captureGeneration,
              mapSourceWorkflowIdentity(mapID, state: state,
                projectSessionID: expectedSession) == identity,
              mapIdentityRequest(for: mapID) == map else { return }
        await state.boundaryMap.configure(captures: captures)
        guard !Task.isCancelled,
              isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
              state.boundaryCaptureGeneration == captureGeneration,
              mapSourceWorkflowIdentity(mapID, state: state,
                projectSessionID: expectedSession) == identity,
              mapIdentityRequest(for: mapID) == map else { return }
        for capture in captures {
            do {
                let options = try loadBoundaryMapVisualStyles(for: capture)
                _ = state.boundaryMap.installVisualStyles(options, for: capture)
            } catch {
                errorMessage = L10n.text(error.localizedDescription)
            }
        }
    }

    /// Explicit entry point used by the native map's retry action when its
    /// source tree could not be loaded during the normal workflow setup.
    func configureProjectGeometryMap(_ mapID: UUID) async {
        guard let map = mapIdentityRequest(for: mapID) else {
            existingMapState(for: mapID)?.projectGeometryMap.invalidate()
            return
        }
        let expectedSession = projectSessionID
        guard let state = existingMapState(for: mapID) else { return }
        guard let identity = mapSourceWorkflowIdentity(mapID, state: state,
            projectSessionID: expectedSession) else { return }
        do {
            let rows = try await sourceMapLayerRows(mapID)
            let nodes = rows.map(\.node)
            guard !Task.isCancelled,
                  isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
                  mapIdentityRequest(for: mapID) == map,
                  mapSourceWorkflowIdentity(mapID, state: state,
                    projectSessionID: expectedSession) == identity else { return }
            await refreshSourceMapVectors(nodes, mapID: mapID)
            guard !Task.isCancelled,
                  isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
                  mapIdentityRequest(for: mapID) == map,
                  mapSourceWorkflowIdentity(mapID, state: state,
                    projectSessionID: expectedSession) == identity else { return }
            await configureProjectGeometryMap(mapID, map: map, identity: identity, rows: rows)
        } catch {
            guard !Task.isCancelled,
                  isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
                  mapIdentityRequest(for: mapID) == map,
                  mapSourceWorkflowIdentity(mapID, state: state,
                    projectSessionID: expectedSession) == identity else { return }
            state.projectGeometryMap.reportConfigurationError(error.localizedDescription)
        }
    }

    private func canonicalSourcePath(_ path: String?) -> String? {
        path.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0)) }
    }
    /// Re-resolves the complete saved map tree before retrying Boundary
    /// captures. This covers stale or incomplete preflight identity as well as
    /// backend read failures held by the boundary session itself.
    func refreshBoundaryMap(_ mapID: UUID) async {
        guard let map = mapIdentityRequest(for: mapID) else {
            existingMapState(for: mapID)?.boundaryMap.invalidate()
            return
        }
        let expectedSession = projectSessionID
        guard let state = existingMapState(for: mapID) else { return }
        guard let identity = mapSourceWorkflowIdentity(mapID, state: state,
            projectSessionID: expectedSession) else { return }
        state.boundaryCaptureGeneration &+= 1
        let refreshGeneration = state.boundaryCaptureGeneration
        // Capture the exact MapTree request up front. It includes any
        // non-Latest slot-zero MultiResult override; the backend re-resolves
        // this tree before we rebuild only the Boundary captures.
        let context = sourceMapTreeContext(mapID)
        do {
            let rows = try await sourceMapLayerRows(mapID, context: context)
            guard !Task.isCancelled,
                  isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
                  state.boundaryCaptureGeneration == refreshGeneration,
                  mapSourceWorkflowIdentity(mapID, state: state,
                    projectSessionID: expectedSession) == identity,
                  mapIdentityRequest(for: mapID) == map else { return }
            await configureBoundaryMap(mapID, map: map, identity: identity, rows: rows)
        } catch {
            guard !Task.isCancelled,
                  isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
                  state.boundaryCaptureGeneration == refreshGeneration,
                  mapSourceWorkflowIdentity(mapID, state: state,
                    projectSessionID: expectedSession) == identity else { return }
            if error is CancellationError { return }
            errorMessage = L10n.text(error.localizedDescription)
        }
    }
    func resetMapResultSelections(_ mapID: UUID) async {
        guard !isRunningProjectTool, !isSavingAll else { return }
        let state = mapState(for: mapID)
        invalidateMapCharts(mapID: mapID)
        state.resultMap.invalidate(); state.resultSources.invalidate()
        state.resultSelectionOverrides = []; state.resultSourceIdentity = nil
        await configureMapResultSources(mapID)
    }

    /// The persisted tree node owns display identity. File URLs own IO only.
    func sourceVectorInstanceID(_ node: LayerTreeNode, mapID: UUID) -> String {
        "source-vector/\(mapID.uuidString)/\(node.id)"
    }

    func sourceMapVectorKind(_ node: LayerTreeNode) -> MapFeature.Kind? {
        switch node.sourceLocator?.mapType {
        case "PointsVector": .point
        case "PolylinesVector": .line
        case "PolygonsVector": .polygon
        default: nil
        }
    }

    func sourceMapVectorURL(_ node: LayerTreeNode) -> URL? {
        guard let locator = node.sourceLocator, locator.nodeType == "MapLayer",
              ["PointsVector", "PolylinesVector", "PolygonsVector"].contains(locator.mapType ?? ""),
              let directory = document?.directory,
              let assetID = node.assetID,
              let assetURL = try? PlatformPaths.resolve(assetID, relativeTo: directory, mappings: pathMappings),
              FileManager.default.fileExists(atPath: assetURL.path),
              let presentationURL = sourceMapVectorIdentityURL(node),
              ["geojson", "json", "shp"].contains(presentationURL.pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: presentationURL.path),
              SourceFilePaths.canonical(presentationURL) == SourceFilePaths.canonical(assetURL) else { return nil }

        return presentationURL
    }

    /// A path identity for the persisted source node, even while its backing
    /// file is unavailable. Callers may use this to retain a hidden binding;
    /// only `sourceMapVectorURL` admits it to readers or style providers.
    func sourceMapVectorIdentityURL(_ node: LayerTreeNode) -> URL? {
        guard let locator = node.sourceLocator, locator.nodeType == "MapLayer",
              ["PointsVector", "PolylinesVector", "PolygonsVector"].contains(locator.mapType ?? ""),
              let directory = document?.directory else { return nil }

        let assetURL = node.assetID.flatMap {
            try? PlatformPaths.resolve($0, relativeTo: directory, mappings: pathMappings)
        }
        let physicalPath = assetURL.map(SourceFilePaths.canonical)
        for reference in [locator.filenameRelative, locator.filename].compactMap({ $0 }) {
            let normalizedReference = reference.replacingOccurrences(of: "\\", with: "/")
            guard ["geojson", "json", "shp"].contains(
                URL(fileURLWithPath: normalizedReference).pathExtension.lowercased()),
                let presentationURL = try? PlatformPaths.resolvePresentationPath(reference, relativeTo: directory,
                    mappings: pathMappings) else { continue }
            if let physicalPath, SourceFilePaths.canonical(presentationURL) != physicalPath { continue }
            return presentationURL
        }

        // Some source snapshots retain only AssetID. This fallback preserves
        // node identity; the readable-URL gate above still checks vector format,
        // existence, and equality with the Host-owned asset.
        return assetURL
    }

    func sourceMapVectorReadRequests(_ nodes: [LayerTreeNode], mapID: UUID) -> MapVectorSourceReadRequests {
        MapVectorSourceLoader.capture(nodes: nodes, mapID: mapID) { [weak self] node in
            self?.sourceMapVectorURL(node)
        }
    }

    func cancelSourceMapVectorLoad(mapID: UUID) {
        guard let state = sourceMapVectorLoadStates[mapID], state.isActive,
              state.phase != .cancelling else { return }
        sourceMapVectorLoadStates[mapID] = state.replacing(phase: .cancelling)
        sourceMapVectorLoadTasks[mapID]?.cancel()
    }

    /// Applies a true TerrainInput valid extent to the exact current map only
    /// while its editor row and source revision still match the captured row.
    @discardableResult
    func zoomTerrainInputToMap(session: ModelEditorSession, inputID: String,
                               sourceRevision: String, extent: TerrainInputValidExtent,
                               mapID: UUID, expectedProjectSessionID: UUID,
                               expectedMapIdentity: String) -> Bool {
        guard extent.isFiniteAndOrdered,
              projectSessionID == expectedProjectSessionID,
              !isOpeningProject, !isClosingTab, !isSavingAll, !isRunningProjectTool,
              session.loaded, !session.isBusy,
              let modelAssetID = session.modelAssetID,
              let terrainAsset = assets.first(where: { $0.id == modelAssetID && $0.section == .terrains }),
              SourceFilePaths.canonical(URL(fileURLWithPath: modelAssetID))
                == SourceFilePaths.canonical(terrainAsset.url),
              session.sourceFileRevision?.caseInsensitiveCompare(sourceRevision) == .orderedSame,
              let collection = session.sourceCollections[TerrainEditorContract.sourceField],
              collection.terrainConnected,
              collection.items.filter({ $0.id == inputID }).count == 1,
              collection.itemDetails[inputID]?.terrainInfo?.validExtent == extent,
              lastActiveMapID == mapID,
              mapWorkflowIdentity(mapID) == expectedMapIdentity,
              mapIdentityRequest(for: mapID) != nil else { return false }

        let state = mapState(for: mapID)
        guard isCurrentMapState(state, mapID: mapID, projectSessionID: expectedProjectSessionID),
              mapWorkflowIdentity(mapID) == expectedMapIdentity else { return false }
        state.viewport = ViewportRequest(
            lowerLeft: MapPoint(x: extent.minX, y: extent.minY),
            upperRight: MapPoint(x: extent.maxX, y: extent.maxY),
            animated: true, padding: 32)
        activateMap(mapID)
        activeTab = mapID == MapState.projectMapID ? .page(.map) : .map(mapID)
        return true
    }

    private func configureTerrainInputMap(mapID: UUID, state: MapState,
                                          projectSessionID expectedSession: UUID,
                                          workflowIdentity: String) {
        let provider = (modelProvider as? BackendModelProvider).map {
            BackendTerrainInputMapProvider(client: $0.client)
        }
        state.terrainInputMap.configure(mapRequest: mapResultRequest(for: mapID),
            resultSelectionOverrides: sourceMapTreeContext(mapID).resultSelectionOverrides,
            projectSessionID: expectedSession, mapWorkflowIdentity: workflowIdentity,
            provider: provider,
            isCurrent: { [weak self, weak state] in
                guard let self, let state else { return false }
                return self.isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession)
                    && self.mapSourceWorkflowIdentity(mapID) == workflowIdentity
            },
            canReadSource: { [weak self] in
                guard let self else { return false }
                return !self.isRunningProjectTool && !self.isSavingAll
                    && !self.isOpeningProject && !self.isClosingTab
            })
    }

    func setSourceMapVisibility(_ node: LayerTreeNode, checked: Bool, mapID: UUID) async -> Bool {
        if ["ChannelModTerrainInputParentVC", "LeveeModTerrainInputVC",
            "PolygonRasterModTerrainInputVisualContext"].contains(node.sourceClass) {
            guard let state = existingMapState(for: mapID),
                  let terrainPath = node.assetID, node.checked != nil else { return false }
            let project = projectSessionID
            let workflow = mapSourceWorkflowIdentity(mapID)
            if checked {
                guard !isRunningProjectTool, !isSavingAll, !isOpeningProject, !isClosingTab else { return false }
                configureTerrainInputMap(mapID: mapID, state: state,
                    projectSessionID: project, workflowIdentity: workflow)
            }
            await state.terrainInputMap.setChecked(nodeID: node.id, sourceClass: node.sourceClass,
                terrainPath: terrainPath, isChecked: checked)
            return isCurrentMapState(state, mapID: mapID, projectSessionID: project)
                && mapSourceWorkflowIdentity(mapID) == workflow
                && state.terrainInputMap.isChecked(node.id) == checked
                && state.terrainInputMap.error(for: node.id) == nil
        }
        guard !isRunningProjectTool, !isSavingAll, !isOpeningProject, !isClosingTab,
              let provider = layerTreeProvider as? BackendMapTreeProvider,
              let requestedLocator = node.sourceLocator,
              let initialMapIdentity = mapIdentityRequest(for: mapID) else { return false }
        let project = projectSessionID
        let workflowIdentity = mapSourceWorkflowIdentity(mapID)
        let context = sourceMapTreeContext(mapID)
        do {
            // Refresh locator cache for this exact map before performing an action.
            let refreshedTree = try await provider.load(context)
            guard projectSessionID == project,
                  mapIdentityRequest(for: mapID) == initialMapIdentity,
                  mapSourceWorkflowIdentity(mapID) == workflowIdentity,
                  sourceMapTreeContext(mapID) == context,
                  let refreshedNode = refreshedTree.roots.compactMap({ $0.find(node.id) }).first(where: {
                      $0.sourceLocator == requestedLocator
                  }) else { return false }
            _ = try await provider.perform(.visibility(id: refreshedNode.id, checked: checked), context: context)
            guard projectSessionID == project,
                  sameSavedMapOwner(mapIdentityRequest(for: mapID), as: initialMapIdentity) else { return false }
            await configureMapResultSources(mapID)
            return projectSessionID == project
                && sameSavedMapOwner(mapIdentityRequest(for: mapID), as: initialMapIdentity)
        } catch { if projectSessionID == project { errorMessage = L10n.text(error.localizedDescription) }; return false }
    }

    /// Creates a saved Type=Geometry map and focuses this exact project asset
    /// in the same .vis transaction, matching the retained Focus In New View
    /// action. The opened map is selected only after the receipt is read back.
    func focusGeometryInNewMap(assetID: String) async -> Bool {
        guard !isSavingAll, !isRunningProjectTool, !isOpeningProject, !isClosingTab,
              let projectURL = document?.url,
              let backend = layerTreeProvider as? BackendMapTreeProvider,
              let asset = geometryAsset(assetID: assetID) else { return false }
        let projectSession = projectSessionID
        do {
            let path = asset.url.standardizedFileURL.path
            let revision = try await Self.mapSourceRevision(asset.url)
            guard projectSessionID == projectSession, document?.url == projectURL,
                  let currentAsset = geometryAsset(assetID: assetID),
                  SourceFilePaths.canonical(currentAsset.url) == SourceFilePaths.canonical(asset.url) else { return false }
            let receipt = try await backend.createMap(projectPath: projectURL.standardizedFileURL.path,
                kind: "Geometry", initialGeometryPath: path, initialGeometryRevision: revision)
            guard projectSessionID == projectSession,
                  receipt.mapType == "Geometry",
                  let map = catalogMapDocuments.first(where: {
                      $0.sourceIndex == receipt.mapIndex && $0.name == receipt.mapName && $0.kind == "Geometry"
                  }), let id = UUID(uuidString: map.id), let document = mapDocument(for: id),
                  document.kind == .geometry else { return false }
            openMapDocument(document)
            await configureMapResultSources(id)
            return projectSessionID == projectSession && mapIdentityRequest(for: id)?.mapType == "Geometry"
        } catch is CancellationError {
            return false
        } catch {
            if projectSessionID == projectSession { errorMessage = L10n.text(error.localizedDescription) }
            return false
        }
    }

    /// Focuses an existing Geometry in a saved Geometry map, preserving the
    /// source tree's focused order. This is also exposed separately so tests
    /// and native menus can distinguish focus from Buildable membership.
    func focusGeometryInMap(assetID: String, mapID: UUID) async -> Bool {
        guard mapDocument(for: mapID)?.kind == .geometry else { return false }
        return await addGeometryToMap(assetID: assetID, mapID: mapID)
    }

    /// Adds an existing project Geometry through the map-specific retained
    /// action. Geometry maps focus it; Buildable maps add it under Layers.
    func addGeometryToMap(assetID: String, mapID: UUID) async -> Bool {
        guard !isSavingAll, !isRunningProjectTool, !isOpeningProject, !isClosingTab,
              let projectURL = document?.url,
              let backend = layerTreeProvider as? BackendMapTreeProvider,
              let map = mapDocument(for: mapID), map.kind == .geometry || map.kind == .buildable,
              let asset = geometryAsset(assetID: assetID) else { return false }
        let projectSession = projectSessionID
        let mapIdentity = mapIdentityRequest(for: mapID)
        guard let mapIdentity else { return false }
        do {
            let path = asset.url.standardizedFileURL.path
            let revision = try await Self.mapSourceRevision(asset.url)
            guard projectSessionID == projectSession, document?.url == projectURL,
                  mapIdentityRequest(for: mapID) == mapIdentity,
                  let currentAsset = geometryAsset(assetID: assetID),
                  SourceFilePaths.canonical(currentAsset.url) == SourceFilePaths.canonical(asset.url) else { return false }
            _ = try await backend.addGeometry(sourcePath: path, revision: revision,
                context: sourceMapTreeContext(mapID))
            guard projectSessionID == projectSession,
                  let refreshed = mapIdentityRequest(for: mapID),
                  refreshed.mapID == mapIdentity.mapID, refreshed.mapIndex == mapIdentity.mapIndex,
                  refreshed.mapName == mapIdentity.mapName, refreshed.mapType == mapIdentity.mapType else { return false }
            await configureMapResultSources(mapID)
            return projectSessionID == projectSession && mapIdentityRequest(for: mapID)?.mapID == mapIdentity.mapID
        } catch is CancellationError {
            return false
        } catch {
            if projectSessionID == projectSession { errorMessage = L10n.text(error.localizedDescription) }
            return false
        }
    }

    /// Removes one exact focused/membership Geometry tree row. Project
    /// Geometry content and its HDF file remain untouched.
    func removeGeometryFromMap(nodeID: String, mapID: UUID) async -> Bool {
        guard !isSavingAll, !isRunningProjectTool, !isOpeningProject, !isClosingTab,
              let backend = layerTreeProvider as? BackendMapTreeProvider,
              let map = mapDocument(for: mapID), map.kind == .geometry || map.kind == .buildable,
              let initialMapIdentity = mapIdentityRequest(for: mapID),
              let directory = document?.directory else { return false }
        let projectSession = projectSessionID
        do {
            let currentNodes = try await sourceMapLayerNodes(mapID)
            guard projectSessionID == projectSession,
                  mapIdentityRequest(for: mapID) == initialMapIdentity,
                  let row = currentNodes.first(where: { $0.id == nodeID }),
                  row.sourceLocator?.nodeType == "Geometry",
                  let locator = row.sourceLocator,
                  let assetID = row.assetID ?? locator.assetID,
                  !assetID.isEmpty else { return false }
            let sourceURL = try PlatformPaths.resolve(assetID, relativeTo: directory, mappings: pathMappings)
            guard sourceURL.isFileURL,
                  ["h5", "hdf"].contains(sourceURL.pathExtension.lowercased()),
                  FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw BackendServiceError(code: "sourceChanged", message: "The selected Geometry source file is no longer available.")
            }
            let path = sourceURL.standardizedFileURL.path
            let revision = try await Self.mapSourceRevision(sourceURL)
            guard projectSessionID == projectSession,
                  mapIdentityRequest(for: mapID) == initialMapIdentity else { return false }
            _ = try await backend.removeSourceNode(nodeID: nodeID, sourcePath: path, revision: revision,
                context: sourceMapTreeContext(mapID))
            guard projectSessionID == projectSession else { return false }
            await configureMapResultSources(mapID)
            return projectSessionID == projectSession
        } catch is CancellationError {
            return false
        } catch {
            if projectSessionID == projectSession { errorMessage = L10n.text(error.localizedDescription) }
            return false
        }
    }

    private func geometryAsset(assetID: String) -> ProjectAsset? {
        assets.first(where: { $0.id == assetID && $0.section == .geometries && $0.isModelFile })
    }

    /// Creates a saved Plan map and optionally focuses the exact selected Plan
    /// in the same visualization commit. This is distinct from the sidebar's
    /// Plan tree mode and never resolves a Plan by its display name.
    @discardableResult
    func createPlanMap(focusedPlanAssetID: String? = nil) async -> Bool {
        guard !isSavingAll, !isRunningProjectTool, !isOpeningProject, !isClosingTab,
              let projectURL = document?.url,
              let backend = layerTreeProvider as? BackendMapTreeProvider else { return false }
        let projectSession = projectSessionID
        do {
            let plan = focusedPlanAssetID.flatMap(planAsset(assetID:))
            guard focusedPlanAssetID == nil || plan != nil else { return false }
            let planRevision: String?
            if let plan {
                planRevision = try await Self.mapSourceRevision(plan.url)
            } else {
                planRevision = nil
            }
            guard projectSessionID == projectSession, document?.url == projectURL,
                  focusedPlanAssetID == nil
                    || focusedPlanAssetID.flatMap(planAsset(assetID:))?.url == plan?.url else { return false }
            let receipt = try await backend.createMap(projectPath: projectURL.standardizedFileURL.path,
                kind: "Plan", initialPlanPath: plan?.url.standardizedFileURL.path,
                initialPlanRevision: planRevision)
            guard projectSessionID == projectSession, receipt.mapType == "Plan",
                  let map = catalogMapDocuments.first(where: {
                      $0.sourceIndex == receipt.mapIndex && $0.name == receipt.mapName && $0.kind == "Plan"
                  }), let id = UUID(uuidString: map.id), let document = mapDocument(for: id),
                  document.kind == .plan else { return false }
            openMapDocument(document)
            await configureMapResultSources(id)
            return projectSessionID == projectSession && mapIdentityRequest(for: id)?.mapType == "Plan"
        } catch is CancellationError {
            return false
        } catch {
            if projectSessionID == projectSession { errorMessage = L10n.text(error.localizedDescription) }
            return false
        }
    }

    func focusPlanInNewMap(assetID: String) async -> Bool {
        await createPlanMap(focusedPlanAssetID: assetID)
    }

    func focusPlanInMap(assetID: String, mapID: UUID) async -> Bool {
        guard !isSavingAll, !isRunningProjectTool, !isOpeningProject, !isClosingTab,
              let projectURL = document?.url,
              let provider = layerTreeProvider as? BackendMapTreeProvider,
              mapDocument(for: mapID)?.kind == .plan,
              let asset = planAsset(assetID: assetID),
              let initialMapIdentity = mapIdentityRequest(for: mapID) else { return false }
        let projectSession = projectSessionID
        do {
            let sourceRevision = try await Self.mapSourceRevision(asset.url)
            guard projectSessionID == projectSession, document?.url == projectURL,
                  mapIdentityRequest(for: mapID) == initialMapIdentity,
                  planAsset(assetID: assetID)?.url == asset.url else { return false }
            _ = try await provider.focusPlan(sourcePath: asset.url.standardizedFileURL.path,
                revision: sourceRevision, context: sourceMapTreeContext(mapID))
            guard projectSessionID == projectSession,
                  let updated = mapIdentityRequest(for: mapID),
                  updated.mapID == initialMapIdentity.mapID, updated.mapIndex == initialMapIdentity.mapIndex,
                  updated.mapName == initialMapIdentity.mapName, updated.mapType == "Plan" else { return false }
            await configureMapResultSources(mapID)
            return projectSessionID == projectSession && mapIdentityRequest(for: mapID)?.mapType == "Plan"
        } catch is CancellationError {
            return false
        } catch {
            if projectSessionID == projectSession { errorMessage = L10n.text(error.localizedDescription) }
            return false
        }
    }

    func removePlanFromMap(nodeID: String, mapID: UUID) async -> Bool {
        guard !isSavingAll, !isRunningProjectTool, !isOpeningProject, !isClosingTab,
              mapDocument(for: mapID)?.kind == .plan,
              let provider = layerTreeProvider as? BackendMapTreeProvider,
              let initialMapIdentity = mapIdentityRequest(for: mapID) else { return false }
        let projectSession = projectSessionID
        do {
            let rows = try await sourceMapLayerRows(mapID)
            guard projectSessionID == projectSession,
                  mapIdentityRequest(for: mapID) == initialMapIdentity,
                  let row = rows.first(where: { $0.node.id == nodeID }),
                  let locator = row.node.sourceLocator,
                  locator.isFocusedPlanOwner,
                  locator.nodePath?.count == 2,
                  let sourcePath = row.node.assetID ?? locator.assetID,
                  let directory = document?.directory else { return false }
            let sourceURL = try PlatformPaths.resolve(sourcePath, relativeTo: directory, mappings: pathMappings)
            let revision = try await Self.mapSourceRevision(sourceURL)
            guard projectSessionID == projectSession, mapIdentityRequest(for: mapID) == initialMapIdentity else { return false }
            _ = try await provider.removeSourceNode(nodeID: nodeID, sourcePath: sourceURL.path,
                revision: revision, context: sourceMapTreeContext(mapID))
            guard projectSessionID == projectSession else { return false }
            await configureMapResultSources(mapID)
            return projectSessionID == projectSession && mapIdentityRequest(for: mapID)?.mapType == "Plan"
        } catch is CancellationError {
            return false
        } catch {
            if projectSessionID == projectSession { errorMessage = L10n.text(error.localizedDescription) }
            return false
        }
    }

    private func planAsset(assetID: String) -> ProjectAsset? {
        assets.first { $0.id == assetID && $0.section == .plans && $0.isModelFile }
    }

    func setSourceResultViewState(node: LayerTreeNode, mapID: UUID,
                                  selectedMapType: String?, profileIndex: Int?) async -> Bool {
        guard let locator = node.sourceLocator else { return false }
        return await persistSourceResultViewState(node: locator, mapID: mapID,
            selectedMapType: selectedMapType, profileIndex: profileIndex,
            expectedWorkflowIdentity: nil)
    }

    func persistSourceResultViewState(node locator: CatalogTreeNodeLocator, mapID: UUID,
                                      selectedMapType: String?, profileIndex: Int?,
                                      expectedWorkflowIdentity: String?) async -> Bool {
        guard !isRunningProjectTool, !isSavingAll, !isOpeningProject, !isClosingTab,
              ["Result", "MultiResult"].contains(locator.nodeType),
              let provider = layerTreeProvider as? BackendMapTreeProvider,
              let initialMapIdentity = mapIdentityRequest(for: mapID),
              mapState(for: mapID).resultSources.snapshot?.sources.activeNodes.contains(where: {
                  $0.node == locator
              }) == true else { return false }
        let projectSession = projectSessionID
        let currentWorkflowIdentity = mapSourceWorkflowIdentity(mapID)
        guard expectedWorkflowIdentity == nil || expectedWorkflowIdentity == currentWorkflowIdentity else { return false }
        let context = sourceMapTreeContext(mapID)
        do {
            _ = try await provider.setResultViewState(node: locator, selectedMapType: selectedMapType,
                profileIndex: profileIndex, context: context)
            guard projectSessionID == projectSession,
                  sameSavedMapOwner(mapIdentityRequest(for: mapID), as: initialMapIdentity) else { return false }
            await configureMapResultSources(mapID)
            return projectSessionID == projectSession
                && sameSavedMapOwner(mapIdentityRequest(for: mapID), as: initialMapIdentity)
        } catch {
            if projectSessionID == projectSession { errorMessage = L10n.text(error.localizedDescription) }
            return false
        }
    }

    func setSourceResultMapType(_ type: String, mapID: UUID) async -> Bool {
        guard !isRunningProjectTool, !isSavingAll, !isOpeningProject, !isClosingTab,
              let provider = layerTreeProvider as? BackendMapTreeProvider,
              let initialMapIdentity = mapIdentityRequest(for: mapID) else { return false }
        let project = projectSessionID
        let context = sourceMapTreeContext(mapID)
        do {
            _ = try await provider.setResultMapType(mapType: type, context: context)
            guard projectSessionID == project,
                  sameSavedMapOwner(mapIdentityRequest(for: mapID), as: initialMapIdentity) else { return false }
            await configureMapResultSources(mapID)
            return projectSessionID == project
                && sameSavedMapOwner(mapIdentityRequest(for: mapID), as: initialMapIdentity)
        } catch { if projectSessionID == project { errorMessage = L10n.text(error.localizedDescription) }; return false }
    }

    func configureMapResultRendering(_ mapID: UUID) {
        guard let state = existingMapState(for: mapID) else { return }
        guard let snapshot = state.resultSources.snapshot else { state.resultMap.invalidate(); return }
        let identity = snapshot.identity, token = snapshot.sources.contextToken
        state.resultMap.configure(snapshot: snapshot, projectSessionID: projectSessionID,
            viewport: { [weak state] in state?.resultViewport },
            isCurrent: { [weak self, weak state] in
                self?.mapWorkflowIdentity(mapID) == identity && state?.resultSources.snapshot?.sources.contextToken == token
            })
    }

    /// Capture exactly one native component; MultiLineString parts are never
    /// joined into a fabricated sample line.
    func mapLineContext(mapID: UUID, editingSelection: Bool = false) throws -> MapResultChartContext {
        let state = mapState(for: mapID)
        guard let map = mapResultRequest(for: mapID) else { throw MapResultChartCaptureError.unsupportedLineShape }
        let layerID: String
        let lineID: String
        let points: [MapPoint]
        let url: URL
        let revision: String
        let generation: String
        let editor = state.polylineEditor
        if editingSelection {
            guard !editor.isSourceStale, let scope = editor.currentScope, let line = editor.selectedLine,
                  line.canEdit, let source = editor.currentSourceRevision else { throw MapResultChartCaptureError.unsupportedLineShape }
            layerID = scope.layerID; lineID = line.id; points = line.points
            url = URL(fileURLWithPath: scope.canonicalPath); revision = source; generation = editor.draftGeneration
        } else {
            guard let selectedLayer = state.selectedLayerID, let selectedLine = state.selectedLineIdentity,
                  let layer = state.visibleVectors(mapLayers).first(where: { $0.id == selectedLayer }),
                  let source = layer.sourceRevision else {
                throw MapResultChartCaptureError.unsupportedLineShape
            }
            let matches = layer.features.filter { $0.kind == .line && $0.hasUniqueStableIdentity && $0.pathStableIdentities.contains(selectedLine) }
            guard matches.count == 1, let feature = matches.first,
                  let index = feature.pathStableIdentities.firstIndex(of: selectedLine), feature.paths.indices.contains(index) else {
                throw MapResultChartCaptureError.unsupportedLineShape
            }
            layerID = layer.id; lineID = selectedLine; points = feature.paths[index]; url = layer.url; revision = source
            if editor.currentScope?.layerID == layer.id {
                guard !editor.isSourceStale else { throw MapResultChartCaptureError.unsupportedLineShape }
                generation = editor.draftGeneration
            } else { generation = "disk:" + source }
        }
        return MapResultChartContext(capture: try .init(projectSessionID: projectSessionID, mapID: mapID,
            projectPath: URL(fileURLWithPath: map.projectPath), projectXML: map.projectXml,
            mapIndex: map.mapIndex, mapName: map.mapName, mapType: map.mapType,
            visualizationRevision: map.expectedVisualizationRevision, layerID: layerID, vectorPath: url,
            vectorRevision: revision, stableFeatureIdentity: lineID,
            coordinates: points.map { .init(x: $0.x, y: $0.y) }, draftGeneration: generation))
    }

    func openMapLineChart(mapID: UUID, mode: MapResultChartMode, editingSelection: Bool = false) -> DetachedDocumentRoute? {
        do {
            let context = try mapLineContext(mapID: mapID, editingSelection: editingSelection)
            let state = mapState(for: mapID)
            guard let snapshot = state.resultSources.snapshot, snapshot.map == context.mapRequest,
                  !snapshot.sources.activeNodes.isEmpty, let backend = modelProvider as? BackendModelProvider else {
                errorMessage = L10n.text("Load the map's active result sources before opening a line chart.")
                return nil
            }
            let session = MapResultChartSession(context: context, sourceSnapshot: snapshot, mode: mode,
                provider: BackendMapResultChartProvider(client: backend.client), isCurrent: { [weak self, weak state] in
                    guard let self, let state, state.resultSources.snapshot == snapshot else { return false }
                    return (try? self.mapLineContext(mapID: mapID, editingSelection: editingSelection)) == context
                })
            let id = registerMapChart(session)
            return .init(projectSessionID: projectSessionID, editor: nil, mapID: mapID, mapChart: .init(sessionID: id))
        } catch {
            errorMessage = L10n.text("Select one unambiguous polyline component with at least two points before opening a chart.")
            return nil
        }
    }

    func openMapDynamicProfileWindow(mapID: UUID, mode: MapDynamicProfileWindowMode,
                                     editingSelection: Bool = false) -> DetachedDocumentRoute? {
        guard !isRunningPlanCompute else {
            errorMessage = L10n.text("Map profile sampling is unavailable while the project is computing.")
            return nil
        }
        guard let client = dynamicProfileBackendClient else {
            errorMessage = L10n.text("Map profile sampling is unavailable.")
            return nil
        }
        do {
            let context = try mapLineContext(mapID: mapID, editingSelection: editingSelection)
            let state = mapState(for: mapID)
            let profile = MapDynamicProfileWindowPresentation(
                title: L10n.format("%@ Profile Plot", mapName(mapID)), mode: mode)
            if let existing = mapDynamicProfileWindows.values.first(where: { candidate in
                candidate.matches(projectSessionID: projectSessionID, mapID: mapID,
                    context: context, mode: mode,
                    editingSelection: editingSelection)
                    && isCurrentMapDynamicProfileWindow(candidate, state: state)
            }) {
                return .init(projectSessionID: projectSessionID, editor: nil, mapID: mapID,
                    dynamicProfile: .init(sessionID: existing.id))
            }
            guard let sources = state.resultSources.snapshot,
                  sources.map == context.mapRequest,
                  sources.identity == mapWorkflowIdentity(mapID) else {
                errorMessage = L10n.text("Load the map source context before opening a profile plot.")
                return nil
            }
            if mode == .results && sources.sources.activeNodes.isEmpty {
                errorMessage = L10n.text("Load active result sources before opening a Results Profile Plot.")
                return nil
            }
            let session = MapDynamicProfileWindowSession(mapState: state,
                projectSessionID: projectSessionID, context: context, sources: sources,
                sourceWorkflowIdentity: mapSourceWorkflowIdentity(mapID),
                mapWorkflowIdentity: mapWorkflowIdentity(mapID), editingSelection: editingSelection,
                presentation: profile,
                sampler: MapDynamicProfileSession(provider: BackendMapDynamicProfileProvider(client: client)))
            guard isCurrentMapDynamicProfileWindow(session, state: state) else {
                session.close()
                errorMessage = L10n.text("The selected map, result source, or polyline changed.")
                return nil
            }
            let id = registerMapDynamicProfileWindow(session)
            return .init(projectSessionID: projectSessionID, editor: nil, mapID: mapID,
                dynamicProfile: .init(sessionID: id))
        } catch {
            errorMessage = L10n.text("Select one unambiguous polyline component with at least two points before opening a profile plot.")
            return nil
        }
    }
}

extension MapState {
    var resultViewport: RasterMapViewExtent? {
        guard referencePoints != nil, let extent = currentExtent, extent.isFiniteAndOrdered,
              canvasPixelSize.width > 0, canvasPixelSize.height > 0 else { return nil }
        let ratio = min(1, 1024 / max(canvasPixelSize.width, canvasPixelSize.height))
        return .init(minX: extent.lowerLeft.x, minY: extent.lowerLeft.y, maxX: extent.upperRight.x, maxY: extent.upperRight.y,
            pixelWidth: max(1, Int((canvasPixelSize.width * ratio).rounded())),
            pixelHeight: max(1, Int((canvasPixelSize.height * ratio).rounded())))
    }
}
