import CryptoKit
import Foundation
import RASWorkspaceCore

enum MapResultChartMode: String, CaseIterable, Identifiable, Sendable {
    case flow = "Flow"
    case cumulativeVolume = "CumulativeVolume"

    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .flow: "Flow Time Series"
        case .cumulativeVolume: "Volume Accumulation Time Series"
        }
    }
}

enum MapResultSelectionMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case latest = "Latest"
    case previous = "Previous"
    case explicit = "Explicit"

    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .latest: "Latest Result"
        case .previous: "Previous Result"
        case .explicit: "Explicit"
        }
    }
}

/// Immutable map-line selection captured by the map entry point. The feature
/// identity comes from MapVectorLayer's source identity, while coordinates
/// may represent the current map draft rather than the old disk geometry.
struct MapResultChartLineCapture: Hashable, Sendable {
    let projectSessionID: UUID
    let mapID: UUID
    let projectPath: String
    let projectXML: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let visualizationRevision: String
    let layerID: String
    let vectorPath: String
    let vectorRevision: String
    let stableFeatureIdentity: String
    let coordinates: [GeometryTopologyCoordinate]
    let draftGeneration: String
    let coreLayerContext: CoreLayerRequestContext?

    init(projectSessionID: UUID, mapID: UUID, projectPath: URL, projectXML: String,
         mapIndex: Int, mapName: String, mapType: String, visualizationRevision: String,
         layerID: String, vectorPath: URL, vectorRevision: String, stableFeatureIdentity: String,
         coordinates: [GeometryTopologyCoordinate], draftGeneration: String,
         coreLayerContext: CoreLayerRequestContext? = nil) throws {
        guard (2...10_000).contains(coordinates.count), coordinates.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              !layerID.isEmpty, !stableFeatureIdentity.isEmpty, !vectorRevision.isEmpty,
              !visualizationRevision.isEmpty, !draftGeneration.isEmpty else {
            throw MapResultChartCaptureError.unsupportedLineShape
        }
        self.projectSessionID = projectSessionID
        self.mapID = mapID
        // Keep the project's caller-selected base path: relative paths in the
        // in-memory project XML resolve from this standardized directory. Use
        // physical canonicalization only for the vector-file identity.
        self.projectPath = projectPath.standardizedFileURL.path
        self.projectXML = projectXML
        self.mapIndex = mapIndex
        self.mapName = mapName
        self.mapType = mapType
        self.visualizationRevision = visualizationRevision
        self.layerID = layerID
        self.vectorPath = SourceFilePaths.canonical(vectorPath)
        self.vectorRevision = vectorRevision
        self.stableFeatureIdentity = stableFeatureIdentity
        self.coordinates = coordinates
        self.draftGeneration = draftGeneration
        self.coreLayerContext = coreLayerContext
    }

}

struct MapResultChartContext: Hashable, Sendable {
    let capture: MapResultChartLineCapture
    let projectXMLSHA: String
    let coordinateSHA: String

    init(capture: MapResultChartLineCapture) {
        self.capture = capture
        projectXMLSHA = Self.digest(Data(capture.projectXML.utf8))
        coordinateSHA = Self.coordinateDigest(capture.coordinates)
    }

    var projectSessionID: UUID { capture.projectSessionID }
    var mapID: UUID { capture.mapID }
    var projectPath: String { capture.projectPath }
    var projectXML: String { capture.projectXML }
    var mapIndex: Int { capture.mapIndex }
    var mapName: String { capture.mapName }
    var mapType: String { capture.mapType }
    var visualizationRevision: String { capture.visualizationRevision }
    var layerID: String { capture.layerID }
    var vectorPath: String { capture.vectorPath }
    var vectorRevision: String { capture.vectorRevision }
    var stableFeatureIdentity: String { capture.stableFeatureIdentity }
    var sampleLine: [GeometryTopologyCoordinate] { capture.coordinates }
    var draftGeneration: String { capture.draftGeneration }
    var coreLayerContext: CoreLayerRequestContext? { capture.coreLayerContext }

    var mapRequest: MapResultChartMapRequest {
        MapResultChartMapRequest(
            projectPath: projectPath,
            projectXml: projectXML,
            projectXmlSHA: projectXMLSHA,
            mapID: mapID.uuidString,
            mapIndex: mapIndex,
            mapName: mapName,
            mapType: mapType,
            expectedVisualizationRevision: visualizationRevision,
            coreLayerContext: capture.coreLayerContext)
    }

    func expectedFeatureContextToken(contextToken: String, mode: MapResultChartMode) -> String {
        let payload = ["HECRAS-MAP-SAMPLE-v1", contextToken, vectorPath,
            stableFeatureIdentity, vectorRevision.uppercased(), coordinateSHA.uppercased(),
            mode.rawValue].joined(separator: "\0")
        return Self.digest(Data(payload.utf8))
    }

    var identity: String {
        [projectSessionID.uuidString, mapID.uuidString, projectPath, projectXMLSHA,
         String(mapIndex), mapName, mapType, visualizationRevision, layerID, vectorPath,
         vectorRevision, stableFeatureIdentity, coordinateSHA, draftGeneration,
         coreLayerContext?.identityToken ?? ""].joined(separator: "|")
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    static func coordinateDigest(_ coordinates: [GeometryTopologyCoordinate]) -> String {
        var bytes = Data("HECRAS-MAP-LINE-v1\0".utf8)
        for coordinate in coordinates {
            var x = coordinate.x.bitPattern.bigEndian
            var y = coordinate.y.bitPattern.bigEndian
            withUnsafeBytes(of: &x) { bytes.append(contentsOf: $0) }
            withUnsafeBytes(of: &y) { bytes.append(contentsOf: $0) }
        }
        return digest(bytes)
    }
}

enum MapResultChartCaptureError: Error, Equatable {
    case unsupportedLineShape
}

struct MapResultChartMapRequest: Codable, Hashable, Sendable {
    let projectPath: String
    let projectXml: String
    let projectXmlSHA: String
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let expectedVisualizationRevision: String
    var computeReadLease: MapResultComputeReadLease? = nil
    var coreLayerContext: CoreLayerRequestContext? = nil
}

struct MapResultComputeReadLease: Codable, Hashable, Sendable {
    let projectSessionID: String
    let runID: String
    let projectPath: String
    let protectedSourcePaths: [String]
    var callbackResultPath: String? = nil

    var canonicalProtectedSourcePaths: Set<String> {
        Set(protectedSourcePaths.map {
            SourceFilePaths.canonical(URL(fileURLWithPath: $0))
        })
    }

    func validates(map: MapResultChartMapRequest,
                   capture: WorkspaceResultComputeCapture,
                   entry: WorkspaceResultComputeEntry) -> Bool {
        guard UUID(uuidString: projectSessionID) == capture.projectSessionID,
              UUID(uuidString: runID)?.uuidString.caseInsensitiveCompare(entry.runID) == .orderedSame,
              Self.samePath(projectPath, capture.projectPath),
              Self.samePath(map.projectPath, capture.projectPath),
              map.projectXmlSHA.caseInsensitiveCompare(capture.projectXmlFingerprint) == .orderedSame,
              !protectedSourcePaths.isEmpty, protectedSourcePaths.count <= 64 else { return false }
        var paths: Set<String> = []
        for rawPath in protectedSourcePaths {
            guard Self.isSupportedHDFPath(rawPath) else { return false }
            let canonical = SourceFilePaths.canonical(URL(fileURLWithPath: rawPath))
            guard paths.insert(canonical).inserted else { return false }
        }
        guard let callbackResultPath,
              Self.isSupportedHDFPath(callbackResultPath),
              paths.contains(SourceFilePaths.canonical(URL(fileURLWithPath: callbackResultPath))),
              Self.samePath(callbackResultPath, entry.resultPath) else { return false }
        return true
    }

    private static func isSupportedHDFPath(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        return url.path.hasPrefix("/") && ["h5", "hdf"].contains(url.pathExtension.lowercased())
    }

    private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        SourceFilePaths.canonical(URL(fileURLWithPath: lhs))
            == SourceFilePaths.canonical(URL(fileURLWithPath: rhs))
    }
}

/// Selection overrides deliberately live in the native per-map session. The
/// retained ResultSelection state is not serialized in the .vis document.
struct MapResultSelectionOverride: Codable, Hashable, Sendable {
    let node: CatalogTreeNodeLocator
    let selectionIndex: Int
    let mode: MapResultSelectionMode
    let resultPath: String?
    let resultRevision: String?

    init(node: CatalogTreeNodeLocator, selectionIndex: Int = 0, mode: MapResultSelectionMode,
         resultPath: String? = nil, resultRevision: String? = nil) {
        self.node = node
        self.selectionIndex = selectionIndex
        self.mode = mode
        self.resultPath = resultPath
        self.resultRevision = resultRevision
    }

    var nodeIdentity: String {
        node.sourceIdentity
    }

    var id: String { "\(nodeIdentity)|\(selectionIndex)" }
}

struct MapResultChartSelectionSlot: Decodable, Equatable, Identifiable, Sendable {
    let selectionIndex: Int
    let selectionMode: MapResultSelectionMode
    let selectedResult: MapResultChartSourceChoice?
    let choices: [MapResultChartSourceChoice]
    var id: Int { selectionIndex }
}

struct MapResultChartSourcesRequest: Encodable, Sendable {
    let map: MapResultChartMapRequest
    let selectionOverrides: [MapResultSelectionOverride]
}

struct MapResultChartSelectionRequest: Encodable, Sendable {
    let map: MapResultChartMapRequest
    let expectedContextToken: String
    let currentSelectionOverrides: [MapResultSelectionOverride]
    let selectionOverrides: [MapResultSelectionOverride]
}

struct MapResultChartSampleLineRequest: Encodable, Sendable {
    let map: MapResultChartMapRequest
    let contextToken: String
    let selectionOverrides: [MapResultSelectionOverride]
    let sampleLine: [GeometryTopologyCoordinate]
    let mode: String
    let feature: MapResultFeatureIdentity

    init(context: MapResultChartContext, contextToken: String,
         selectionOverrides: [MapResultSelectionOverride], mode: MapResultChartMode) {
        map = context.mapRequest
        self.contextToken = contextToken
        self.selectionOverrides = selectionOverrides
        sampleLine = context.sampleLine
        self.mode = mode.rawValue
        feature = MapResultFeatureIdentity(vectorPath: context.vectorPath,
            vectorRevision: context.vectorRevision, featureID: context.stableFeatureIdentity,
            coordinateSHA: context.coordinateSHA)
    }
}

struct MapResultFeatureIdentity: Codable, Hashable, Sendable {
    let vectorPath: String
    let vectorRevision: String
    let featureID: String
    let coordinateSHA: String
}

struct MapResultChartSourceChoice: Decodable, Equatable, Identifiable, Sendable {
    let resultPath: String
    let revision: String
    let resultName: String
    let planName: String?
    let endTime: String?
    let isComputing: Bool
    /// Persisted state and diagnostics belong to this exact Result path/revision.
    /// Older backend snapshots omit these fields and remain unknown.
    var computeState: String? = nil
    var computeFailureReason: String? = nil
    var diagnosticStatus: String? = nil
    var layerErrors: [CatalogLayerDiagnostic]? = nil
    var diagnosticReadError: String? = nil
    var id: String { Self.canonical(resultPath) }

    private static func canonical(_ path: String) -> String { SourceFilePaths.canonical(URL(fileURLWithPath: path)) }
}

enum MultiResultContextRouteProjection {
    /// Map-source rows are tied to their complete locator identity. A display
    /// name match or a Plan name match is never sufficient to route a detail.
    static func exactActiveNodeID(for locator: CatalogTreeNodeLocator,
                                  among nodes: [MapResultChartActiveNode]) -> String? {
        let matches = nodes.filter { $0.nodeKind == "MultiResult" && $0.node == locator }
        guard matches.count == 1 else { return nil }
        return matches[0].id
    }

    /// The Result editor may auto-route only when exactly one active map group
    /// currently selects this exact Result file. Ambiguous membership requires
    /// an explicit group choice in the UI.
    static func uniquelySelectedGroupID(for resultPath: String,
                                        among nodes: [MapResultChartActiveNode]) -> String? {
        let expected = canonicalPath(resultPath)
        let matches = nodes.filter { node in
            node.nodeKind == "MultiResult" && node.selections.contains { slot in
                guard slot.selectionIndex == 0, let selected = slot.selectedResult else { return false }
                return canonicalPath(selected.resultPath) == expected
            }
        }
        guard matches.count == 1 else { return nil }
        return matches[0].id
    }

    /// Catalog MultiResult rows without a serialized map locator can route
    /// only by the exact owning Plan path carried by the active map node.
    /// Plan display names and embedded filenames are not identities.
    @MainActor
    static func activeGroups(forPlanAssetID planAssetID: String,
                             among nodes: [MapResultChartActiveNode]) -> [MapResultChartActiveNode] {
        let expected = canonicalPath(planAssetID)
        return nodes.filter { candidate in
            guard candidate.nodeKind == "MultiResult",
                  let owner = WorkspaceStore.exactPlanOwnerForResultGroup(candidate.node) else { return false }
            return canonicalPath(owner.assetID) == expected
        }
    }

    static func canonicalPath(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }
}

struct MapResultChartActiveNode: Decodable, Equatable, Identifiable, Sendable {
    let node: CatalogTreeNodeLocator
    let nodeKind: String
    let name: String
    let selections: [MapResultChartSelectionSlot]
    let selectedMapType: String?
    let profileIndex: Int?

    var id: String {
        MapResultSelectionOverride(node: node, mode: .latest).nodeIdentity
    }
}

struct MapResultChartSources: Decodable, Equatable, Sendable {
    let projectPath: String
    let projectRevision: String
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let projectXmlSHA: String
    let visualizationRevision: String
    let contextToken: String
    let activeNodes: [MapResultChartActiveNode]
}

struct MapResultSourcesSnapshot: Equatable, Sendable {
    let map: MapResultChartMapRequest
    let identity: String
    let sources: MapResultChartSources
    let selectionOverrides: [MapResultSelectionOverride]
}

struct MapResultChartSelectionIdentity: Decodable, Hashable, Identifiable, Sendable {
    let node: CatalogTreeNodeLocator
    let selectionIndex: Int

    var id: String {
        MapResultSelectionOverride(node: node, selectionIndex: selectionIndex, mode: .latest).id
    }
}

struct MapResultChartSeriesEntry: Decodable, Identifiable, Sendable {
    let selections: [MapResultChartSelectionIdentity]
    let selectedMapType: String?
    let profileIndex: Int?
    let series: ResultProfileSampleLineSeries

    var id: String {
        let selectionIDs = selections.map(\.id).sorted()
        return selectionIDs.joined(separator: ",") + "|" + (selectedMapType ?? "") + "|"
            + String(profileIndex ?? -1) + "|" + Self.canonical(series.resultPath) + "|" + series.revision
    }

    private static func canonical(_ path: String) -> String { SourceFilePaths.canonical(URL(fileURLWithPath: path)) }
}

struct MapResultChartSeries: Decodable, Sendable {
    let projectPath: String
    let projectRevision: String
    let projectXmlSHA: String
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let visualizationRevision: String
    let contextToken: String
    let featureContextToken: String
    let feature: MapResultFeatureIdentity
    let mode: String
    let sampleLine: [GeometryTopologyCoordinate]
    let series: [MapResultChartSeriesEntry]
    var sideEffects: [MapResultChartSideEffect] = []
}

struct MapResultChartSideEffect: Decodable, Identifiable, Sendable {
    let code: String
    let path: String?
    var id: String { code + "|" + (path ?? "") }
}

@MainActor
protocol MapResultChartProvider {
    func loadSources(map: MapResultChartMapRequest,
                     selectionOverrides: [MapResultSelectionOverride]) async throws -> MapResultChartSources
    func selectSources(map: MapResultChartMapRequest, expectedContextToken: String,
                       currentSelectionOverrides: [MapResultSelectionOverride],
                       selectionOverrides: [MapResultSelectionOverride]) async throws -> MapResultChartSources
    func compute(_ request: MapResultChartSampleLineRequest,
                 progress: @escaping @Sendable (BackendProgressUpdate) -> Void) async throws -> MapResultChartSeries
}
