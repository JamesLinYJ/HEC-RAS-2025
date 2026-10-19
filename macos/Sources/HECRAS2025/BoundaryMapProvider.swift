import CryptoKit
import Foundation
import RASWorkspaceCore

@MainActor
protocol BoundaryMapProvider {
    func load(_ capture: BoundaryMapCapture, boundarySourceState: String?,
              contextToken: String?) async throws -> BoundaryMapSnapshot
}

/// Reads source BoundaryConditionLine polylines for one exact saved-map row.
/// The source HDF and Project document are verified before and after the
/// request so late data cannot be displayed over a changed owner.
@MainActor
final class BackendBoundaryMapProvider: BoundaryMapProvider {
    private let client: BackendProcessClient
    private let isCurrent: @MainActor (BoundaryMapCapture) -> Bool

    init(client: BackendProcessClient? = nil,
         isCurrent: @escaping @MainActor (BoundaryMapCapture) -> Bool = { _ in true }) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
        self.isCurrent = isCurrent
    }

    func load(_ capture: BoundaryMapCapture, boundarySourceState: String?,
              contextToken: String?) async throws -> BoundaryMapSnapshot {
        guard isCurrent(capture), !Task.isCancelled else { throw BoundaryMapError.staleContext }
        let sourceURL = URL(fileURLWithPath: capture.sourcePath)
        let projectURL = URL(fileURLWithPath: SourceFilePaths.canonical(URL(fileURLWithPath: capture.map.projectPath)))
        let sourceRevisionBefore = try await Self.sourceRevision(at: sourceURL)
        let projectRevisionBefore = try await Self.sourceRevision(at: projectURL)
        guard isCurrent(capture), !Task.isCancelled else { throw CancellationError() }
        guard Self.sameRevision(sourceRevisionBefore, capture.sourceRevision),
              Self.isSHA256(projectRevisionBefore) else { throw BoundaryMapError.sourceChanged }

        let request = BoundaryMapRequest(map: capture.map, boundaryNode: capture.boundaryNode,
            expectedBoundaryRevision: capture.sourceRevision,
            boundarySourceState: boundarySourceState, expectedContextToken: contextToken,
            resultOwner: capture.resultOwner)
        let snapshot: BoundaryMapSnapshot = try await client.request(
            "map.boundary.geometry.load", parameters: request, as: BoundaryMapSnapshot.self)

        guard isCurrent(capture), !Task.isCancelled else { throw CancellationError() }
        try validate(snapshot, capture: capture, requestedBoundarySourceState: boundarySourceState,
                     previousContextToken: contextToken,
                     projectRevision: projectRevisionBefore)
        let sourceRevisionAfter = try await Self.sourceRevision(at: sourceURL)
        let projectRevisionAfter = try await Self.sourceRevision(at: projectURL)
        guard isCurrent(capture), !Task.isCancelled else { throw CancellationError() }
        guard Self.sameRevision(sourceRevisionAfter, capture.sourceRevision),
              Self.sameRevision(projectRevisionAfter, projectRevisionBefore) else {
            throw BoundaryMapError.sourceChanged
        }
        return snapshot
    }

    private func validate(_ snapshot: BoundaryMapSnapshot, capture: BoundaryMapCapture,
                          requestedBoundarySourceState: String?, previousContextToken: String?,
                          projectRevision: String) throws {
        let map = capture.map
        guard SourceFilePaths.canonical(URL(fileURLWithPath: snapshot.projectCanonicalPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: map.projectPath)),
              Self.sameRevision(snapshot.projectRevision, projectRevision),
              Self.sameRevision(snapshot.projectXmlSHA, map.projectXmlSHA),
              Self.sameRevision(snapshot.visualizationRevision, map.expectedVisualizationRevision),
              snapshot.mapID.caseInsensitiveCompare(map.mapID) == .orderedSame,
              snapshot.mapIndex == map.mapIndex,
              snapshot.mapName == map.mapName,
              snapshot.mapType == map.mapType,
              !snapshot.contextToken.isEmpty,
              snapshot.boundaryNode == capture.boundaryNode,
              SourceFilePaths.canonical(URL(fileURLWithPath: snapshot.boundaryPath)) == capture.sourcePath,
              Self.sameRevision(snapshot.boundaryRevision, capture.sourceRevision),
              snapshot.boundaryChecked == capture.isChecked,
              snapshot.boundaryEffectiveVisible == capture.effectiveVisible,
              Self.matchesResultOwner(snapshot.resultOwner, expected: capture.resultOwner),
              !snapshot.boundarySourceState.isEmpty,
              Self.uniqueLines(snapshot.lines) else {
            throw BoundaryMapError.mismatchedReply
        }
        if let previousContextToken, snapshot.contextToken != previousContextToken {
            throw BoundaryMapError.sourceChanged
        }
        if let boundarySourceState = requestedBoundarySourceState,
           snapshot.boundarySourceState != boundarySourceState {
            throw BoundaryMapError.sourceChanged
        }
        if let status = snapshot.status,
           !["available", "hidden", "empty", "unavailable", "failed"].contains(status) {
            throw BoundaryMapError.mismatchedReply
        }
    }

    static func sourceState(from snapshot: BoundaryMapSnapshot,
                            capture: BoundaryMapCapture) throws -> BoundaryMapSourceState {
        guard Self.uniqueLines(snapshot.lines) else { throw BoundaryMapError.invalidGeometry }
        var invalidGeometryCount = 0
        let lines = snapshot.lines.map { item -> BoundaryMapLine in
            let sourceCoordinates = item.coordinates ?? []
            let finite = sourceCoordinates.allSatisfy { $0.x.isFinite && $0.y.isFinite }
            let coordinates: [MapPoint]
            if finite && sourceCoordinates.count >= 2 {
                coordinates = sourceCoordinates.map { MapPoint(x: $0.x, y: $0.y) }
            } else {
                invalidGeometryCount += 1
                coordinates = []
            }
            return BoundaryMapLine(id: item.id, sourceOrdinal: item.sourceOrdinal,
                name: item.name,
                coordinates: coordinates)
        }
        let validCount = lines.reduce(0) { $0 + ($1.coordinates.count >= 2 ? 1 : 0) }
        let status: BoundaryMapSourceStatus
        switch snapshot.status {
        case "hidden": status = .hidden
        case "empty": status = .empty
        case "failed": status = .failed
        case "unavailable": status = .failed
        case "available": status = validCount == 0 ? .empty : .available
        case .none: status = capture.effectiveVisible ? (validCount == 0 ? .empty : .available) : .hidden
        default: status = .failed
        }
        let diagnostic: String?
        if let sourceDiagnostic = snapshot.diagnostic, !sourceDiagnostic.isEmpty {
            diagnostic = sourceDiagnostic
        } else if invalidGeometryCount > 0 {
            diagnostic = L10n.text("Some Boundary Condition lines have no valid map geometry.")
        } else {
            diagnostic = nil
        }
        return BoundaryMapSourceState(capture: capture, contextToken: snapshot.contextToken,
            boundarySourceState: snapshot.boundarySourceState, lines: lines,
            status: status, diagnostic: diagnostic)
    }

    private static func uniqueLines(_ lines: [BoundaryMapLineData]) -> Bool {
        var ids = Set<String>()
        var ordinals = Set<Int>()
        for line in lines {
            guard !line.id.isEmpty, line.sourceOrdinal >= 0,
                  ids.insert(line.id).inserted, ordinals.insert(line.sourceOrdinal).inserted else { return false }
        }
        return true
    }

    private static func matchesResultOwner(_ actual: BoundaryMapResultOwnerReceipt?,
                                           expected: MapResultOwnerSelection?) -> Bool {
        guard let expected else { return actual == nil }
        return actual?.matches(expected) == true
    }

    private static func sourceRevision(at url: URL) async throws -> String {
        let worker = Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: bytes)
            }
            return hasher.finalize().map { String(format: "%02X", $0) }.joined()
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func sameRevision(_ left: String, _ right: String) -> Bool {
        left.caseInsensitiveCompare(right) == .orderedSame
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}
