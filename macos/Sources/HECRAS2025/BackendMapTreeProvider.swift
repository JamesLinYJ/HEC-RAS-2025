import CryptoKit
import Foundation
import RASWorkspaceCore

struct MapDocumentMutationReceipt: Sendable, Equatable {
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let previousVisualizationRevision: String?
    let visualizationRevision: String
}

struct MapDocumentDeleteIndexChange: Decodable, Sendable, Equatable {
    let previousMapIndex: Int
    let mapIndex: Int
    let mapName: String
    let mapType: String
}

struct MapDocumentDeleteReceipt: Decodable, Sendable, Equatable {
    let removedMapIndex: Int
    let removedMapName: String
    let removedMapType: String
    let previousVisualizationRevision: String
    let visualizationRevision: String
    let mapIndexChanges: [MapDocumentDeleteIndexChange]
}

struct MapVectorImportReceipt: Sendable, Equatable {
    let map: MapDocumentMutationReceipt
    let refreshWarning: String?
}

/// Source-backed persistence for saved Project, Buildable, Plan, and Geometry
/// map trees. The caller supplies the exact saved map identity from `.vis`.
@MainActor
final class BackendMapTreeProvider: LayerTreeProvider {
    private let client: BackendProcessClient
    private let fallback: (any LayerTreeProvider)?
    private let projectXML: @MainActor () -> String?
    private let mapDocuments: @MainActor () -> [CatalogMapDocument]
    private let isContextCurrent: @MainActor (LayerTreeContext) -> Bool
    private let visualizationRevision: @MainActor () -> String?
    private let beginMapMutation: @MainActor () -> Bool
    private let endMapMutation: @MainActor () -> Void
    private let acceptMapChange: @MainActor (String?, String) throws -> Void
    private var mutationRunning = false
    private var cachedMapID: String?
    private var locatorByNodeID: [String: CatalogTreeNodeLocator] = [:]

    init(
        client: BackendProcessClient? = nil,
        fallback: (any LayerTreeProvider)? = nil,
        projectXML: @escaping @MainActor () -> String?,
        mapDocuments: @escaping @MainActor () -> [CatalogMapDocument],
        isContextCurrent: @escaping @MainActor (LayerTreeContext) -> Bool = { _ in true },
        visualizationRevision: @escaping @MainActor () -> String?,
        beginMapMutation: @escaping @MainActor () -> Bool = { true },
        endMapMutation: @escaping @MainActor () -> Void = {},
        acceptMapChange: @escaping @MainActor (String?, String) throws -> Void = { _, _ in }
    ) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
        self.fallback = fallback
        self.projectXML = projectXML
        self.mapDocuments = mapDocuments
        self.isContextCurrent = isContextCurrent
        self.visualizationRevision = visualizationRevision
        self.beginMapMutation = beginMapMutation
        self.endMapMutation = endMapMutation
        self.acceptMapChange = acceptMapChange
    }

    func createMap(projectPath: String, kind: String, name: String? = nil,
                   initialGeometryPath: String? = nil,
                   initialGeometryRevision: String? = nil,
                   initialPlanPath: String? = nil,
                   initialPlanRevision: String? = nil) async throws -> MapDocumentMutationReceipt {
        guard ["Project", "Buildable", "Geometry", "Plan"].contains(kind),
              (initialGeometryPath == nil) == (initialGeometryRevision == nil),
              initialGeometryPath == nil || kind == "Geometry",
              (initialPlanPath == nil) == (initialPlanRevision == nil),
              initialPlanPath == nil || kind == "Plan",
              initialGeometryPath == nil || initialPlanPath == nil else {
            throw BackendServiceError(code: "unsupported", message: "The requested saved map type or initial Geometry source is not supported.")
        }
        try beginMutation()
        defer { endMutation() }
        let snapshot = projectSnapshot()
        let response = try await client.request("map.document.create", parameters: MapDocumentRequestPayload(
            projectPath: projectPath,
            projectXml: snapshot.xml,
            projectXmlSHA: snapshot.sha,
            expectedVisualizationRevision: visualizationRevision(),
            kind: kind,
            name: name,
            initialGeometryPath: initialGeometryPath,
            initialGeometryRevision: initialGeometryRevision,
            initialPlanPath: initialPlanPath,
            initialPlanRevision: initialPlanRevision
        ), as: MapDocumentMutationResponse.self)
        let receipt = response.value
        try acceptIfChanged(previous: receipt.previousVisualizationRevision, current: receipt.visualizationRevision)
        return receipt
    }

    /// Removes only the exact saved .vis map row. Callers apply the returned
    /// index mapping to their existing runtime map identities after accepting
    /// the new visualization revision; duplicate map names remain safe.
    func deleteMap(projectPath: String, map: CatalogMapDocument) async throws -> MapDocumentDeleteReceipt {
        guard let mapIndex = map.sourceIndex, let expectedRevision = map.visualizationRevision else {
            throw BackendServiceError(code: "sourceChanged", message: "The selected map is not saved in the current visualization file.")
        }
        try beginMutation()
        defer { endMutation() }
        let snapshot = projectSnapshot()
        let response = try await client.request("map.document.delete", parameters: MapDocumentRequestPayload(
            projectPath: projectPath,
            projectXml: snapshot.xml,
            projectXmlSHA: snapshot.sha,
            expectedVisualizationRevision: expectedRevision,
            kind: map.kind,
            mapID: map.id,
            mapIndex: mapIndex,
            mapName: map.name,
            mapType: map.kind
        ), as: MapDocumentDeleteReceipt.self)
        guard response.removedMapIndex == mapIndex,
              response.removedMapName == map.name,
              response.removedMapType == map.kind,
              response.previousVisualizationRevision.caseInsensitiveCompare(expectedRevision) == .orderedSame,
              response.mapIndexChanges.allSatisfy({
                  $0.previousMapIndex >= 0 && $0.previousMapIndex != mapIndex
                      && $0.mapIndex == ($0.previousMapIndex > mapIndex
                        ? $0.previousMapIndex - 1 : $0.previousMapIndex)
              }),
              Set(response.mapIndexChanges.map(\.previousMapIndex)).count == response.mapIndexChanges.count,
              Set(response.mapIndexChanges.map(\.mapIndex)) == Set(0..<response.mapIndexChanges.count) else {
            throw BackendServiceError(code: "sourceChanged", message: "The map deletion reply does not match the selected saved map.")
        }
        return response
    }

    func renameMap(projectPath: String, map: CatalogMapDocument, to name: String) async throws -> MapDocumentMutationReceipt {
        guard let mapIndex = map.sourceIndex, let expectedRevision = map.visualizationRevision else {
            throw BackendServiceError(code: "sourceChanged", message: "The selected map is not saved in the current visualization file.")
        }
        try beginMutation()
        defer { endMutation() }
        let snapshot = projectSnapshot()
        let response = try await client.request("map.document.rename", parameters: MapDocumentRequestPayload(
            projectPath: projectPath,
            projectXml: snapshot.xml,
            projectXmlSHA: snapshot.sha,
            expectedVisualizationRevision: expectedRevision,
            kind: map.kind,
            mapID: map.id,
            mapIndex: mapIndex,
            mapName: map.name,
            mapType: map.kind,
            newName: name
        ), as: MapDocumentMutationResponse.self)
        let receipt = response.value
        try acceptIfChanged(previous: receipt.previousVisualizationRevision, current: receipt.visualizationRevision)
        return receipt
    }

    func addResult(resultPath: String, revision: String, context: LayerTreeContext) async throws -> LayerTreeSnapshot {
        let map = try requirePersistentMap(context, allowedKinds: ["Buildable", "Plan", "Geometry"])
        if cachedMapID != map.id { _ = try await load(context) }
        return try await performSourceAction(
            .init(map: mapRequest(context, map: map), action: "addResult",
                  sourcePath: resultPath, sourceRevision: revision),
            mapID: map.id, context: context)
    }

    /// Adds an existing project Geometry to the selected saved map using the
    /// source-specific operation: Geometry maps append a focused Geometry,
    /// while Buildable maps add it beneath Layers.
    func addGeometry(sourcePath: String, revision: String,
                     context: LayerTreeContext) async throws -> LayerTreeSnapshot {
        let map = try requirePersistentMap(context, allowedKinds: ["Geometry", "Buildable"])
        if cachedMapID != map.id { _ = try await load(context) }
        let action = map.kind == "Geometry" ? "focusGeometry" : "addGeometry"
        return try await performSourceAction(
            .init(map: mapRequest(context, map: map), action: action,
                  sourcePath: sourcePath, sourceRevision: revision),
            mapID: map.id, context: context)
    }

    func focusPlan(sourcePath: String, revision: String, context: LayerTreeContext) async throws -> LayerTreeSnapshot {
        let map = try requirePersistentMap(context, allowedKinds: ["Plan"])
        if cachedMapID != map.id { _ = try await load(context) }
        return try await performSourceAction(
            .init(map: mapRequest(context, map: map), action: "focusPlan",
                  sourcePath: sourcePath, sourceRevision: revision),
            mapID: map.id, context: context)
    }

    func setResultViewState(node: CatalogTreeNodeLocator, selectedMapType: String?, profileIndex: Int?,
                            context: LayerTreeContext) async throws -> LayerTreeSnapshot {
        let map = try requirePersistentMap(context, allowedKinds: ["Project", "Buildable", "Plan", "Geometry"])
        guard ["Result", "MultiResult"].contains(node.nodeType),
              profileIndex.map({ $0 >= 0 }) ?? true else {
            throw BackendServiceError(code: "invalidInput", message: "Choose a valid Result map profile and source node.")
        }
        return try await performSourceAction(
            .init(map: mapRequest(context, map: map), action: "setResultViewState", node: node,
                  name: selectedMapType, profileIndex: profileIndex),
            mapID: map.id, context: context)
    }

    func setResultMapType(mapType: String, context: LayerTreeContext) async throws -> LayerTreeSnapshot {
        let map = try requirePersistentMap(context, allowedKinds: ["Project", "Buildable", "Plan", "Geometry"])
        return try await performSourceAction(
            .init(map: mapRequest(context, map: map), action: "setResultMapType", name: mapType),
            mapID: map.id, context: context)
    }

    func addGeoJSONVector(sourcePath: String, revision: String, context: LayerTreeContext) async throws -> LayerTreeSnapshot {
        let map = try requirePersistentMap(context, allowedKinds: ["Project", "Buildable", "Geometry", "Plan"])
        return try await performSourceAction(
            .init(map: mapRequest(context, map: map), action: "addGeoJSONVector",
                  sourcePath: sourcePath, sourceRevision: revision),
            mapID: map.id, context: context)
    }

    func importGeoJSONVector(sourcePath: String, revision: String, projectXML: String, projectRevision: String,
                             context: LayerTreeContext,
                             didPublish: @MainActor () throws -> Void = {}) async throws -> MapVectorImportReceipt {
        try requireCurrentContext(context, matchingRevision: true)
        let map = persistedMap(for: context)
        guard map != nil || (context.mapID == MapState.projectMapID &&
            !mapDocuments().contains(where: { $0.sourceIndex != nil })) else {
            throw BackendServiceError(code: "unsupported", message: "This source map operation is unavailable for the selected map.")
        }
        try beginMutation()
        defer { endMutation() }
        let sha = SHA256.hash(data: Data(projectXML.utf8)).map { String(format: "%02X", $0) }.joined()
        let request = MapDocumentRequestPayload(projectPath: try projectPath(context),
            projectXml: projectXML, projectXmlSHA: sha,
            expectedVisualizationRevision: visualizationRevision(), kind: map?.kind ?? "Project",
            mapID: context.mapID.uuidString, mapIndex: map?.sourceIndex, mapName: map?.name, mapType: map?.kind)
        let expectedSourceCanonicalPath = SourceFilePaths.canonical(URL(fileURLWithPath: sourcePath))
        let response = try await client.request("map.vector.import",
            parameters: MapVectorImportPayload(map: request, sourcePath: sourcePath, sourceRevision: revision,
                expectedProjectRevision: projectRevision, expectedSourceCanonicalPath: expectedSourceCanonicalPath),
            as: MapDocumentMutationResponse.self)
        try requireCurrentContext(context, matchingRevision: false)
        let receipt = response.value
        // Publication already succeeded. Track the corresponding local project
        // draft even if a later raster/catalog refresh reports an error.
        try didPublish()
        do {
            try acceptIfChanged(previous: receipt.previousVisualizationRevision, current: receipt.visualizationRevision)
            return MapVectorImportReceipt(map: receipt, refreshWarning: nil)
        } catch {
            // The host has already committed the map tree and the caller has
            // published the matching project connection draft. Preserve that
            // success receipt so callers can finish their UI update and report
            // the refresh problem separately from the import result.
            return MapVectorImportReceipt(map: receipt, refreshWarning: error.localizedDescription)
        }
    }

    func importRaster(sourcePath: String, revision: String, projectXML: String,
                      projectRevision: String, context: LayerTreeContext,
                      didPublish: @MainActor () throws -> Void = {}) async throws -> MapVectorImportReceipt {
        try requireCurrentContext(context, matchingRevision: true)
        let map = persistedMap(for: context)
        guard map != nil || (context.mapID == MapState.projectMapID &&
            !mapDocuments().contains(where: { $0.sourceIndex != nil })) else {
            throw BackendServiceError(code: "unsupported", message: "This source map operation is unavailable for the selected map.")
        }
        try beginMutation()
        defer { endMutation() }
        let sha = SHA256.hash(data: Data(projectXML.utf8)).map { String(format: "%02X", $0) }.joined()
        let request = MapDocumentRequestPayload(projectPath: try projectPath(context),
            projectXml: projectXML, projectXmlSHA: sha,
            expectedVisualizationRevision: visualizationRevision(), kind: map?.kind ?? "Project",
            mapID: context.mapID.uuidString, mapIndex: map?.sourceIndex, mapName: map?.name, mapType: map?.kind)
        let response = try await client.request("map.raster.import",
            parameters: MapVectorImportPayload(map: request, sourcePath: sourcePath, sourceRevision: revision,
                expectedProjectRevision: projectRevision,
                expectedSourceCanonicalPath: SourceFilePaths.canonical(URL(fileURLWithPath: sourcePath))),
            as: MapDocumentMutationResponse.self)
        try requireCurrentContext(context, matchingRevision: false)
        let receipt = response.value
        try didPublish()
        do {
            try acceptIfChanged(previous: receipt.previousVisualizationRevision, current: receipt.visualizationRevision)
            return MapVectorImportReceipt(map: receipt, refreshWarning: nil)
        } catch {
            return MapVectorImportReceipt(map: receipt, refreshWarning: error.localizedDescription)
        }
    }

    /// Captures the selected Shapefile and every sidecar the retained reader may
    /// use. The caller passes this exact snapshot back to importShapefileVector.
    func captureShapefileFamily(sourcePath: String) async throws -> MapSourceFamilyCapture {
        guard URL(fileURLWithPath: sourcePath).pathExtension.lowercased() == "shp" else {
            throw BackendServiceError(code: "unsupported", message: "Choose a Shapefile (.shp) source file.")
        }
        let response = try await client.request("map.vector.captureShapefile",
            parameters: MapShapefileFamilyCapturePayload(sourcePath: sourcePath),
            as: MapSourceFamilyCapture.self)
        try Self.validateShapefileFamily(response, sourcePath: sourcePath)
        return response
    }

    func importShapefileVector(sourcePath: String, expectedFamily: MapSourceFamilyCapture,
                               projectXML: String, projectRevision: String, context: LayerTreeContext,
                               didPublish: @MainActor () throws -> Void = {}) async throws -> MapVectorImportReceipt {
        try requireCurrentContext(context, matchingRevision: true)
        try Self.validateShapefileFamily(expectedFamily, sourcePath: sourcePath)
        let map = persistedMap(for: context)
        guard map != nil || (context.mapID == MapState.projectMapID &&
            !mapDocuments().contains(where: { $0.sourceIndex != nil })) else {
            throw BackendServiceError(code: "unsupported", message: "This source map operation is unavailable for the selected map.")
        }
        try beginMutation()
        defer { endMutation() }
        let sha = SHA256.hash(data: Data(projectXML.utf8)).map { String(format: "%02X", $0) }.joined()
        let request = MapDocumentRequestPayload(projectPath: try projectPath(context),
            projectXml: projectXML, projectXmlSHA: sha,
            expectedVisualizationRevision: visualizationRevision(), kind: map?.kind ?? "Project",
            mapID: context.mapID.uuidString, mapIndex: map?.sourceIndex, mapName: map?.name, mapType: map?.kind)
        let response = try await client.request("map.vector.importShapefile",
            parameters: MapShapefileVectorImportPayload(map: request, sourcePath: sourcePath,
                expectedProjectRevision: projectRevision, expectedFamily: expectedFamily),
            as: MapDocumentMutationResponse.self)
        try requireCurrentContext(context, matchingRevision: false)
        let receipt = response.value
        try didPublish()
        do {
            try acceptIfChanged(previous: receipt.previousVisualizationRevision, current: receipt.visualizationRevision)
            return MapVectorImportReceipt(map: receipt, refreshWarning: nil)
        } catch {
            return MapVectorImportReceipt(map: receipt, refreshWarning: error.localizedDescription)
        }
    }

    func removeSourceNode(nodeID: String, sourcePath: String? = nil, revision: String? = nil,
                          context: LayerTreeContext) async throws -> LayerTreeSnapshot {
        let map = try requirePersistentMap(context, allowedKinds: ["Project", "Buildable", "Geometry", "Plan"])
        if cachedMapID != map.id { _ = try await load(context) }
        guard let node = locatorByNodeID[nodeID] else { throw missingNode() }
        return try await performSourceAction(
            .init(map: mapRequest(context, map: map), action: "removeSourceNode", node: node,
                  sourcePath: sourcePath, sourceRevision: revision),
            mapID: map.id, context: context)
    }

    func load(_ context: LayerTreeContext) async throws -> LayerTreeSnapshot {
        try requireCurrentContext(context, matchingRevision: false)
        guard let map = persistedMap(for: context) else {
            guard let fallback else {
                throw BackendServiceError(code: "unsupported", message: "This map tree is not connected to a persisted source map.")
            }
            let snapshot = try await fallback.load(context)
            try requireCurrentContext(context, matchingRevision: false)
            return snapshot
        }
        try requireCurrentContext(context, matchingRevision: true)
        let response = try await client.request("map.tree.load", parameters: mapRequest(context, map: map),
            as: MapTreeResponse.self)
        try requireCurrentContext(context, matchingRevision: true)
        return install(response, mapID: map.id)
    }

    func perform(_ action: LayerTreeAction, context: LayerTreeContext) async throws -> LayerTreeSnapshot {
        try requireCurrentContext(context, matchingRevision: false)
        guard let map = persistedMap(for: context) else {
            guard let fallback else {
                throw BackendServiceError(code: "unsupported", message: "This map tree action is not connected to a persisted source map.")
            }
            let snapshot = try await fallback.perform(action, context: context)
            try requireCurrentContext(context, matchingRevision: false)
            return snapshot
        }
        try requireCurrentContext(context, matchingRevision: true)
        if case .select = action { return try await load(context) }
        if cachedMapID != map.id { _ = try await load(context) }
        guard cachedMapID == map.id else { throw missingNode() }
        let request = try mapRequest(context, map: map)
        let actionPayload: MapTreeActionPayload
        switch action {
        case .rename(let id, let name):
            guard let node = locatorByNodeID[id] else { throw missingNode() }
            actionPayload = .init(map: request, action: "rename", node: node, name: name)
        case .visibility(let id, let checked):
            guard let node = locatorByNodeID[id] else { throw missingNode() }
            actionPayload = .init(map: request, action: "visibility", node: node, checked: checked)
        case .move(let ids, let parentID):
            guard let target = locatorByNodeID[parentID] else { throw missingNode() }
            let nodes = try ids.map { id -> CatalogTreeNodeLocator in
                guard let locator = locatorByNodeID[id] else { throw missingNode() }
                return locator
            }
            actionPayload = .init(map: request, action: "move", nodes: nodes, target: target)
        case .newFolder(let parentID, let name):
            guard let target = locatorByNodeID[parentID] else { throw missingNode() }
            actionPayload = .init(map: request, action: "newFolder", target: target, name: name)
        case .pin(let id, let pinned):
            guard let node = locatorByNodeID[id] else { throw missingNode() }
            actionPayload = .init(map: request, action: "pin", node: node, checked: pinned)
        case .saveBackupAsNewGeometry, .contextCommand:
            throw BackendServiceError(code: "unsupported", message: "This source map action is not available in the native map tree.")
        case .select:
            return try await load(context)
        }

        return try await performSourceAction(actionPayload, mapID: map.id, context: context)
    }

    private func performSourceAction(_ action: MapTreeActionPayload, mapID: String,
                                     context: LayerTreeContext) async throws -> LayerTreeSnapshot {
        try beginMutation()
        defer { endMutation() }
        try requireCurrentContext(context, matchingRevision: true)
        let response = try await client.request("map.tree.perform", parameters: action,
            as: MapTreeResponse.self)
        // The .vis write already succeeded. A newer project description or
        // catalog revision must not leave the in-memory visualization baseline
        // behind; accept the receipt, then the view reloads using its new context.
        try requireCurrentContext(context, matchingRevision: false)
        try acceptIfChanged(previous: response.previousVisualizationRevision, current: response.visualizationRevision)
        return install(response, mapID: mapID)
    }

    private func requirePersistentMap(_ context: LayerTreeContext, allowedKinds: Set<String>) throws -> CatalogMapDocument {
        try requireCurrentContext(context, matchingRevision: true)
        guard let map = persistedMap(for: context), allowedKinds.contains(map.kind) else {
            throw BackendServiceError(code: "unsupported", message: "This source map operation is unavailable for the selected map.")
        }
        return map
    }

    private func mapRequest(_ context: LayerTreeContext, map: CatalogMapDocument) throws -> MapTreeRequestPayload {
        guard let mapIndex = map.sourceIndex, let expectedRevision = map.visualizationRevision else {
            throw BackendServiceError(code: "sourceChanged", message: "The selected map is not saved in the current visualization file.")
        }
        if let error = context.resultSelectionError {
            throw BackendServiceError(code: "invalidInput", message: error)
        }
        let snapshot = projectSnapshot()
        return MapTreeRequestPayload(
            projectPath: try projectPath(context), projectXml: snapshot.xml, projectXmlSHA: snapshot.sha,
            mapID: map.id, mapIndex: mapIndex, mapName: map.name, mapType: map.kind,
            expectedVisualizationRevision: expectedRevision,
            resultSelectionOverrides: context.resultSelectionOverrides)
    }

    private func beginMutation() throws {
        guard !mutationRunning, beginMapMutation() else {
            throw BackendServiceError(code: "busy", message: "Another map visualization update is already running.")
        }
        mutationRunning = true
    }

    private func endMutation() {
        guard mutationRunning else { return }
        mutationRunning = false
        endMapMutation()
    }

    private func acceptIfChanged(previous: String?, current: String) throws {
        guard previous.map({ $0.caseInsensitiveCompare(current) == .orderedSame }) != true else { return }
        try acceptMapChange(previous, current)
    }

    private func requireCurrentContext(_ context: LayerTreeContext, matchingRevision: Bool) throws {
        guard isContextCurrent(context) else { throw CancellationError() }
        guard matchingRevision else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let mapsJSON = (try? encoder.encode(mapDocuments())).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let currentRevision = (projectXML() ?? "") + "\n" + mapsJSON
        guard context.projectRevision == currentRevision else { throw CancellationError() }
    }

    private func persistedMap(for context: LayerTreeContext) -> CatalogMapDocument? {
        guard context.mode == "Project",
              let map = mapDocuments().first(where: { $0.id.caseInsensitiveCompare(context.mapID.uuidString) == .orderedSame }),
              map.sourceIndex != nil,
              map.visualizationRevision != nil,
              ["Project", "Buildable", "Geometry", "Plan"].contains(map.kind) else { return nil }
        return map
    }

    private func projectPath(_ context: LayerTreeContext) throws -> String {
        guard let url = context.projectURL else {
            throw BackendServiceError(code: "invalidInput", message: "Open a saved project before loading its map tree.")
        }
        return url.standardizedFileURL.path
    }

    private func projectSnapshot() -> (xml: String?, sha: String?) {
        guard let xml = projectXML() else { return (nil, nil) }
        let digest = SHA256.hash(data: Data(xml.utf8))
        let sha = digest.map { String(format: "%02X", $0) }.joined()
        return (xml, sha)
    }

    private static func validateShapefileFamily(_ family: MapSourceFamilyCapture, sourcePath: String) throws {
        let selectedPath = SourceFilePaths.canonical(URL(fileURLWithPath: sourcePath))
        let sidecars = [
            "source": (selectedPath, true),
            "shx": (URL(fileURLWithPath: selectedPath).deletingPathExtension().appendingPathExtension("shx").path, true),
            "dbf": (URL(fileURLWithPath: selectedPath).deletingPathExtension().appendingPathExtension("dbf").path, true),
            "prj": (URL(fileURLWithPath: selectedPath).deletingPathExtension().appendingPathExtension("prj").path, false)
        ]
        guard family.family == "shapefile", family.revision.count == 64,
              SourceFilePaths.canonical(URL(fileURLWithPath: family.sourcePath)) == selectedPath,
              family.files.count == sidecars.count,
              Set(family.files.map(\.role)) == Set(sidecars.keys) else {
            throw BackendServiceError(code: "sourceChanged", message: "The selected Shapefile family changed. Select it again.")
        }
        for file in family.files {
            guard let (expectedPath, required) = sidecars[file.role], file.required == required,
                  SourceFilePaths.canonical(URL(fileURLWithPath: file.inputPath)) == SourceFilePaths.canonical(URL(fileURLWithPath: expectedPath)),
                  SourceFilePaths.canonical(URL(fileURLWithPath: file.path)) == SourceFilePaths.canonical(URL(fileURLWithPath: expectedPath)),
                  file.exists == (file.revision != nil), (!required || file.exists),
                  file.revision.map({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) ?? !file.exists else {
                throw BackendServiceError(code: "sourceChanged", message: "The selected Shapefile family changed. Select it again.")
            }
        }
    }

    private func install(_ response: MapTreeResponse, mapID: String) -> LayerTreeSnapshot {
        cachedMapID = mapID
        locatorByNodeID.removeAll(keepingCapacity: true)
        let roots = response.roots.map { $0.layerTreeNode(recording: &locatorByNodeID) }
        let selection: LayerTreeSelection? = response.selectedNodeID.map(LayerTreeSelection.node)
        return LayerTreeSnapshot(roots: roots, hiddenLayerIDs: Set(response.hiddenLayerIDs),
            selection: selection, expandedNodeIDs: Set(response.expandedNodeIDs))
    }

    private func missingNode() -> BackendServiceError {
        BackendServiceError(code: "sourceChanged", message: "The selected map tree node is no longer available. Refresh the map tree before editing.")
    }

    private struct MapDocumentRequestPayload: Encodable, Sendable {
        let projectPath: String
        let projectXml: String?
        let projectXmlSHA: String?
        let expectedVisualizationRevision: String?
        let kind: String
        var name: String? = nil
        var initialGeometryPath: String? = nil
        var initialGeometryRevision: String? = nil
        var initialPlanPath: String? = nil
        var initialPlanRevision: String? = nil
        var mapID: String? = nil
        var mapIndex: Int? = nil
        var mapName: String? = nil
        var mapType: String? = nil
        var newName: String? = nil
    }

    private struct MapVectorImportPayload: Encodable, Sendable {
        let map: MapDocumentRequestPayload
        let sourcePath: String
        let sourceRevision: String
        let expectedProjectRevision: String
        let expectedSourceCanonicalPath: String
    }

    private struct MapShapefileFamilyCapturePayload: Encodable, Sendable {
        let sourcePath: String
    }

    private struct MapShapefileVectorImportPayload: Encodable, Sendable {
        let map: MapDocumentRequestPayload
        let sourcePath: String
        let expectedProjectRevision: String
        let expectedFamily: MapSourceFamilyCapture
    }

    private struct MapDocumentMutationResponse: Decodable, Sendable {
        let mapIndex: Int
        let mapName: String
        let mapType: String
        let previousVisualizationRevision: String?
        let visualizationRevision: String
        var value: MapDocumentMutationReceipt {
            .init(mapIndex: mapIndex, mapName: mapName, mapType: mapType,
                  previousVisualizationRevision: previousVisualizationRevision,
                  visualizationRevision: visualizationRevision)
        }
    }

    private struct MapTreeRequestPayload: Encodable, Sendable {
        let projectPath: String
        let projectXml: String?
        let projectXmlSHA: String?
        let mapID: String
        let mapIndex: Int
        let mapName: String
        let mapType: String
        let expectedVisualizationRevision: String?
        var resultSelectionOverrides: [MapTreeResultSelectionOverride] = []
    }

    private struct MapTreeActionPayload: Encodable, Sendable {
        let map: MapTreeRequestPayload
        let action: String
        var node: CatalogTreeNodeLocator? = nil
        var nodes: [CatalogTreeNodeLocator]? = nil
        var target: CatalogTreeNodeLocator? = nil
        var name: String? = nil
        var checked: Bool? = nil
        var sourcePath: String? = nil
        var sourceRevision: String? = nil
        var profileIndex: Int? = nil
    }

    private struct MapTreeResponse: Decodable, Sendable {
        let roots: [MapTreeNodeResponse]
        let previousVisualizationRevision: String?
        let visualizationRevision: String
        var expandedNodeIDs: [String] = []
        var hiddenLayerIDs: [String] = []
        let selectedNodeID: String?
    }

    private struct MapTreeNodeResponse: Decodable, Sendable {
        let id: String
        let sourceClass: String
        let name: String
        var localizeName = false
        var children: [MapTreeNodeResponse]? = nil
        var assetID: String? = nil
        var properties: [MapTreePropertyResponse]? = nil
        var checked: String? = nil
        var isPinned = false
        var canPin = false
        var canRename = false
        var canMove = false
        var canAcceptChildren = false
        var canCreateFolder = false
        var locator: CatalogTreeNodeLocator? = nil
        var layerErrors: [CatalogLayerDiagnostic]? = nil
        var diagnosticStatus: String? = nil
        var diagnosticReadError: String? = nil
        var diagnosticSourceIdentity: String? = nil
        var diagnosticSourceRevision: String? = nil
        var resultComputeState: String? = nil
        var resultComputeFailureReason: String? = nil
        var resultComputeSourcePath: String? = nil
        var resultComputeSourceRevision: String? = nil

        func layerTreeNode(recording locators: inout [String: CatalogTreeNodeLocator]) -> LayerTreeNode {
            if let locator { locators[id] = locator }
            let checkState: LayerTreeNode.CheckState?
            switch checked {
            case "checked": checkState = .checked
            case "unchecked": checkState = .unchecked
            case "mixed": checkState = .mixed
            default: checkState = nil
            }
            return LayerTreeNode(
                id: id,
                sourceClass: sourceClass,
                name: name,
                localizeName: localizeName,
                children: children?.map { $0.layerTreeNode(recording: &locators) },
                checked: checkState,
                isPinned: isPinned,
                canPin: canPin,
                canRename: canRename,
                canMove: canMove,
                canAcceptChildren: canAcceptChildren,
                canCreateFolder: canCreateFolder,
                assetID: assetID,
                properties: properties?.map { .init(id: $0.id, label: $0.label, value: $0.value) } ?? [],
                layerErrors: layerErrors,
                diagnosticStatus: diagnosticStatus,
                diagnosticReadError: diagnosticReadError,
                diagnosticSourceIdentity: diagnosticSourceIdentity,
                diagnosticSourceRevision: diagnosticSourceRevision,
                resultComputeState: resultComputeState,
                resultComputeFailureReason: resultComputeFailureReason,
                resultComputeSourcePath: resultComputeSourcePath,
                resultComputeSourceRevision: resultComputeSourceRevision,
                sourceLocator: locator
            )
        }
    }

    private struct MapTreePropertyResponse: Decodable, Sendable {
        let id: String
        let label: String
        let value: String
    }
}
