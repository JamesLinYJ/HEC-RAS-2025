import CryptoKit
import Foundation
import RASWorkspaceCore

@MainActor
protocol ProjectGeometryMapProvider {
    func load(_ request: MapGeometryRequest,
              capture: ProjectGeometryMapCapture) async throws -> MapGeometrySnapshot
}

@MainActor
final class BackendProjectGeometryMapProvider: ProjectGeometryMapProvider {
    private let client: BackendProcessClient
    private let isCurrent: @MainActor () -> Bool
    private var verifiedSources: [String: VerifiedGeometrySource] = [:]

    private struct VerifiedGeometrySource {
        let contextToken: String
        let revision: String
    }

    init(client: BackendProcessClient? = nil,
         isCurrent: @escaping @MainActor () -> Bool) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
        self.isCurrent = isCurrent
    }

    func load(_ request: MapGeometryRequest,
              capture: ProjectGeometryMapCapture) async throws -> MapGeometrySnapshot {
        guard isCurrent(), request.map == capture.map,
              request.geometryNode == capture.geometryNode,
              request.planNodes == capture.planNodes else {
            throw ProjectGeometryMapError.staleContext
        }
        let sourceURL = URL(fileURLWithPath: capture.geometryCanonicalPath)
        let localRevisionBefore = try await Self.sourceRevision(at: sourceURL)
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        let snapshot: MapGeometrySnapshot
        if let resultOwner = capture.resultOwner {
            let parameters = MapResultGeometryRequest(map: request.map,
                resultOwner: resultOwner, geometryNode: request.geometryNode, request: request)
            let envelope: MapResultGeometrySnapshot = try await client.request(
                "map.result.geometry.load", parameters: parameters, as: MapResultGeometrySnapshot.self)
            try Self.validateResultEnvelope(envelope, request: request, capture: capture,
                                            owner: resultOwner)
            snapshot = envelope.geometry
        } else {
            let nativeRequest = MapGeometryRequest(map: request.map,
                geometryNode: request.geometryNode, viewport: request.viewport,
                contextToken: request.contextToken,
                planNodes: request.planNodes,
                topologyCursor: request.topologyCursor, cellCursor: request.cellCursor,
                culvertCursor: request.culvertCursor,
                skipTopologyPage: request.skipTopologyPage,
                skipFlowAreasPage: request.skipFlowAreasPage,
                skipCulvertsPage: request.skipCulvertsPage, pageSize: request.pageSize)
            snapshot = try await client.request(
                "map.geometry.load", parameters: nativeRequest, as: MapGeometrySnapshot.self)
        }
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        try await validate(snapshot, request: request, capture: capture,
                           sourceURL: sourceURL, localRevisionBefore: localRevisionBefore)
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        return snapshot
    }

    private static func validateResultEnvelope(_ envelope: MapResultGeometrySnapshot,
                                               request: MapGeometryRequest,
                                               capture: ProjectGeometryMapCapture,
                                               owner: MapResultGeometryOwner) throws {
        let map = request.map
        guard envelope.mapID == map.mapID,
              envelope.mapIndex == map.mapIndex,
              envelope.mapName == map.mapName,
              envelope.mapType == map.mapType,
              SourceFilePaths.canonical(URL(fileURLWithPath: envelope.projectCanonicalPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: map.projectPath)),
              !envelope.projectRevision.isEmpty,
              envelope.projectXmlSHA.caseInsensitiveCompare(map.projectXmlSHA) == .orderedSame,
              envelope.visualizationRevision.caseInsensitiveCompare(map.expectedVisualizationRevision)
                == .orderedSame,
              envelope.contextToken == owner.contextToken,
              envelope.resultNode == owner.resultNode,
              envelope.selectionIndex == owner.selectionIndex,
              Self.canonicalPath(envelope.selectedResultPath) == owner.selectedResultPath,
              envelope.selectedResultRevision.caseInsensitiveCompare(owner.selectedResultRevision)
                == .orderedSame,
              envelope.geometryNode == capture.geometryNode,
              Self.canonicalPath(envelope.geometryPath) == capture.geometryCanonicalPath,
              envelope.geometryRevision.caseInsensitiveCompare(owner.selectedResultRevision)
                == .orderedSame,
              envelope.geometry.geometryNode == capture.geometryNode,
              Self.canonicalPath(envelope.geometry.geometryCanonicalPath) == capture.geometryCanonicalPath,
              envelope.geometry.geometryRevision.caseInsensitiveCompare(owner.selectedResultRevision)
                == .orderedSame else {
            throw ProjectGeometryMapError.mismatchedReply
        }
    }

    private static func canonicalPath(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }

    private func validate(_ snapshot: MapGeometrySnapshot, request: MapGeometryRequest,
                          capture: ProjectGeometryMapCapture,
                          sourceURL: URL,
                          localRevisionBefore: String?) async throws {
        let map = request.map
        guard snapshot.mapID == map.mapID,
              snapshot.mapIndex == map.mapIndex,
              snapshot.mapName == map.mapName,
              snapshot.mapType == map.mapType,
              !snapshot.projectRevision.isEmpty,
              SourceFilePaths.canonical(URL(fileURLWithPath: snapshot.projectCanonicalPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: map.projectPath)),
              snapshot.projectXmlSHA?.caseInsensitiveCompare(map.projectXmlSHA) == .orderedSame,
              snapshot.visualizationRevision.caseInsensitiveCompare(map.expectedVisualizationRevision) == .orderedSame,
              snapshot.geometryNode == capture.geometryNode,
              (snapshot.planNodes ?? []) == capture.planNodes,
              snapshot.geometryName == capture.geometryName,
              SourceFilePaths.canonical(URL(fileURLWithPath: snapshot.geometryCanonicalPath))
                == capture.geometryCanonicalPath,
              !snapshot.contextToken.isEmpty else {
            throw ProjectGeometryMapError.mismatchedReply
        }
        if let localRevisionBefore {
            guard Self.isSHA256(localRevisionBefore), Self.isSHA256(snapshot.geometryRevision) else {
                throw ProjectGeometryMapError.mismatchedReply
            }
            guard localRevisionBefore.caseInsensitiveCompare(snapshot.geometryRevision) == .orderedSame else {
                throw ProjectGeometryMapError.sourceChanged
            }
        } else {
            guard snapshot.geometryRevision == "missing" else {
                throw ProjectGeometryMapError.sourceChanged
            }
            guard Self.allGeometrySourcesFailedOrAbsent(snapshot) else {
                throw ProjectGeometryMapError.invalidPage
            }
        }
        if let expected = request.contextToken, snapshot.contextToken != expected {
            throw ProjectGeometryMapError.sourceChanged
        }
        try validatePagePresence(snapshot, request: request)
        try Self.validateLayer(snapshot.topologyState, expectedNodeType: "ConceptualMesh",
                               geometryNode: capture.geometryNode,
                               geometryAssetPath: capture.geometryCanonicalPath,
                               geometryChecked: snapshot.geometryChecked)
        try Self.validateLayer(snapshot.flowAreasState, expectedNodeType: "FlowAreaLayer",
                               geometryNode: capture.geometryNode,
                               geometryAssetPath: capture.geometryCanonicalPath,
                               geometryChecked: snapshot.geometryChecked)
        try Self.validateLayer(snapshot.culvertsState, expectedNodeType: "CulvertBarrelLayer",
                               geometryNode: capture.geometryNode,
                               geometryAssetPath: capture.geometryCanonicalPath,
                               geometryChecked: snapshot.geometryChecked)
        guard !snapshot.geometryEffectiveVisible || snapshot.geometryChecked,
              Self.valid(snapshot.extent) else {
            throw ProjectGeometryMapError.invalidPage
        }

        let captureID = capture.identity
        if let expectedToken = request.contextToken {
            guard let verified = verifiedSources[captureID], verified.contextToken == expectedToken else {
                throw ProjectGeometryMapError.sourceChanged
            }
            guard verified.contextToken == snapshot.contextToken,
                  verified.revision.caseInsensitiveCompare(snapshot.geometryRevision) == .orderedSame else {
                throw ProjectGeometryMapError.sourceChanged
            }
        } else {
            verifiedSources[captureID] = VerifiedGeometrySource(
                contextToken: snapshot.contextToken, revision: snapshot.geometryRevision)
        }
        // The file can be replaced while the backend is reading or paging it.
        // Verify bytes again before returning any geometry to the canvas.
        if let localRevisionBefore {
            let localRevisionAfter: String
            do { localRevisionAfter = try await Self.sha256(at: sourceURL) }
            catch {
                if !FileManager.default.fileExists(atPath: sourceURL.path) {
                    throw ProjectGeometryMapError.sourceChanged
                }
                throw error
            }
            guard localRevisionAfter.caseInsensitiveCompare(localRevisionBefore) == .orderedSame,
                  localRevisionAfter.caseInsensitiveCompare(snapshot.geometryRevision) == .orderedSame else {
                throw ProjectGeometryMapError.sourceChanged
            }
        } else {
            guard !FileManager.default.fileExists(atPath: sourceURL.path),
                  snapshot.geometryRevision == "missing" else {
                throw ProjectGeometryMapError.sourceChanged
            }
        }
    }

    private func validatePagePresence(_ snapshot: MapGeometrySnapshot, request: MapGeometryRequest) throws {
        guard request.skipTopologyPage ? snapshot.topology == nil : snapshot.topology != nil,
              request.skipFlowAreasPage ? snapshot.flowAreas == nil : snapshot.flowAreas != nil,
              request.skipCulvertsPage ? snapshot.culverts == nil : snapshot.culverts != nil else {
            throw ProjectGeometryMapError.incompleteReply
        }

        if let page = snapshot.topology {
            guard page.returnedFeatureCount == page.features.count,
                  page.scannedFeatureCount >= page.returnedFeatureCount,
                  page.scannedFeatureCount <= page.sourceFeatureCount,
                  page.scannedFeatureCount <= 16_384,
                  page.returnedFeatureCount <= request.pageSize,
                  page.sourceFeatureCount >= 0, page.invalidFeatureCount >= 0,
                  page.omittedSourceFeatureCount >= 0,
                  page.omittedSourceFeatureCount <= page.sourceFeatureCount,
                  page.sourceFeatureCount >= page.features.count,
                  page.invalidFeatureCount <= page.scannedFeatureCount,
                  page.complete == (page.nextCursor == nil),
                  page.complete || (page.scannedFeatureCount > 0 && page.nextCursor != request.topologyCursor),
                  Self.valid(page.sourceExtent) else {
                throw ProjectGeometryMapError.invalidPage
            }
            try Self.validate(page.features.flatMap(\.paths).flatMap { $0 })
        }
        if let page = snapshot.flowAreas {
            guard page.returnedCellCount == page.cells.count,
                  page.scannedSourceCellCount >= page.returnedCellCount,
                  page.scannedSourceCellCount <= page.sourceCellCount,
                  page.sourceCellCount >= 0, page.invalidCellCount >= 0,
                  page.invalidCellCount <= page.scannedSourceCellCount,
                  page.scannedSourceCellCount <= 16_384,
                  page.returnedCellCount <= request.pageSize,
                  page.complete == (page.nextCursor == nil),
                  page.complete || (page.scannedSourceCellCount > 0 && page.nextCursor != request.cellCursor),
                  Self.valid(page.sourceExtent),
                  Set(page.areas.map(\.id)).count == page.areas.count,
                  Set(page.areas.map(\.rowIndex)).count == page.areas.count,
                  page.areas.allSatisfy({ area in
                      area.rowIndex >= 0 && area.cellCount >= 0 && area.faceCount >= 0 && area.nodeCount >= 0
                          && area.targetedCellSpacing.map { $0.isFinite && $0 >= 0 } != false
                          && Self.valid(area.extent)
                  }),
                  !snapshot.flowAreasState.status.hasSourceData
                      || page.sourceCellCount == page.areas.reduce(0, { $0 + max(0, $1.cellCount) }),
                  Self.flowCellsMatchAreas(page.cells, areas: page.areas) else {
                throw ProjectGeometryMapError.invalidPage
            }
            try Self.validate(page.cells.flatMap(\.coordinates))
        }
        if let page = snapshot.culverts {
            guard page.returnedBarrelCount == page.features.count,
                  page.scannedSourceBarrelCount >= page.returnedBarrelCount,
                  page.scannedSourceBarrelCount <= page.sourceBarrelCount,
                  page.scannedSourceBarrelCount <= 16_384,
                  page.returnedBarrelCount <= request.pageSize,
                  page.sourceBarrelCount >= 0, page.invalidFeatureCount >= 0,
                  page.invalidFeatureCount <= page.scannedSourceBarrelCount,
                  page.complete == (page.nextCursor == nil),
                  page.complete || (page.scannedSourceBarrelCount > 0 && page.nextCursor != request.culvertCursor),
                  Self.valid(page.sourceExtent),
                  Set(page.features.map(\.id)).count == page.features.count else {
                throw ProjectGeometryMapError.invalidPage
            }
            try Self.validate(page.features.flatMap(\.polyline))
        }
    }

    static func validateLayer(_ state: MapGeometryLayerState, expectedNodeType: String,
                              geometryNode: CatalogTreeNodeLocator,
                              geometryAssetPath: String,
                              geometryChecked: Bool) throws {
        guard !state.effectiveVisible || (state.isChecked && geometryChecked) else {
            throw ProjectGeometryMapError.invalidPage
        }
        if let locator = state.locator, let nodeID = state.nodeID, !nodeID.isEmpty {
            guard locator.nodeType == expectedNodeType,
                  locator.rootName == geometryNode.rootName,
                  let parentPath = geometryNode.nodePath,
                  !parentPath.isEmpty,
                  !locator.nodeName.isEmpty,
                  locator.parentGeometryAssetID.map({
                      SourceFilePaths.canonical(URL(fileURLWithPath: $0)) == geometryAssetPath
                  }) == true,
                  locator.parentGeometryNodePath == parentPath,
                  locator.parentGeometryNodeName == geometryNode.nodeName else {
                throw ProjectGeometryMapError.invalidPage
            }
            if locator.nodePath == nil {
                // MapTreeService retains these real source children when a
                // sparse .vis file has no serialized child row. They remain
                // unchecked and hidden; parent identity still has to match
                // this exact Geometry row.
                let sourceDefaultGeometryChildren: Set<String> = [
                    "ConceptualMesh", "FlowAreaLayer", "CulvertBarrelLayer"
                ]
                guard sourceDefaultGeometryChildren.contains(expectedNodeType),
                      !state.isChecked, !state.effectiveVisible else {
                    throw ProjectGeometryMapError.invalidPage
                }
                return
            }
            guard let childPath = locator.nodePath,
                  childPath.count == parentPath.count + 1,
                  Array(childPath.prefix(parentPath.count)) == parentPath else {
                throw ProjectGeometryMapError.invalidPage
            }
        } else {
            guard state.nodeID == nil, state.locator == nil,
                  state.status == .unavailable, !state.isChecked,
                  !state.effectiveVisible, state.diagnostic?.isEmpty == false else {
                throw ProjectGeometryMapError.invalidPage
            }
        }
    }

    private static func valid(_ extent: GeometryTopologyExtent?) -> Bool {
        guard let extent else { return true }
        return extent.minX.isFinite && extent.minY.isFinite
            && extent.maxX.isFinite && extent.maxY.isFinite
            && extent.minX <= extent.maxX && extent.minY <= extent.maxY
    }

    private static func valid(_ extent: GeometryMeshExtent?) -> Bool {
        guard let extent else { return true }
        return extent.minX.isFinite && extent.minY.isFinite
            && extent.maxX.isFinite && extent.maxY.isFinite
            && extent.minX <= extent.maxX && extent.minY <= extent.maxY
    }

    private static func validate(_ coordinates: [GeometryTopologyCoordinate]) throws {
        guard coordinates.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw ProjectGeometryMapError.invalidCoordinates
        }
    }

    private static func validate(_ coordinates: [GeometryCulvertCoordinate]) throws {
        guard coordinates.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw ProjectGeometryMapError.invalidCoordinates
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }
    }

    private static func allGeometrySourcesFailedOrAbsent(_ snapshot: MapGeometrySnapshot) -> Bool {
        let states = [snapshot.topologyState, snapshot.flowAreasState, snapshot.culvertsState]
        return states.contains(where: { $0.status == .failed })
            && states.allSatisfy({ $0.status == .failed || $0.status == .unavailable })
    }

    private static func flowCellsMatchAreas(_ cells: [GeometryMeshMapCell],
                                            areas: [MapGeometryFlowAreaSource]) -> Bool {
        let byID = Dictionary(uniqueKeysWithValues: areas.map { ($0.id, $0) })
        return cells.allSatisfy { cell in
            guard let area = byID[cell.flowAreaID] else { return false }
            return cell.meshIndex == area.rowIndex
                && cell.flowAreaName == area.name
                && cell.cellIndex >= 0 && cell.cellIndex < area.cellCount
        }
    }

    private static func sourceRevision(at url: URL) async throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try await sha256(at: url) }
        catch {
            // A concurrent removal is represented by the backend's explicit
            // failed layer states; other local read errors remain visible.
            if !FileManager.default.fileExists(atPath: url.path) { return nil }
            throw error
        }
    }

    private static func sha256(at url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
                hasher.update(data: bytes)
            }
            return hasher.finalize().map { String(format: "%02X", $0) }.joined()
        }.value
    }
}

enum ProjectGeometryMapError: Error, LocalizedError {
    case staleContext
    case mismatchedReply
    case sourceChanged
    case incompleteReply
    case invalidPage
    case invalidCoordinates

    var errorDescription: String? {
        switch self {
        case .staleContext:
            "The selected saved map changed before Geometry could be loaded."
        case .mismatchedReply:
            "The Geometry map reply no longer matches the selected source tree node."
        case .sourceChanged:
            "The Geometry source changed while its map was loading. Refresh the map layers."
        case .incompleteReply:
            "The Geometry map service returned a missing page. Refresh the map layers."
        case .invalidPage:
            "The Geometry map service returned inconsistent page metadata."
        case .invalidCoordinates:
            "The Geometry map service returned non-finite coordinates."
        }
    }
}
