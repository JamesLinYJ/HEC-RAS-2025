import CryptoKit
import Foundation
import RASWorkspaceCore

@MainActor
protocol StoredCulvertProfileProvider {
    func load(capture: StoredCulvertProfileCapture,
              profileIndex: Int) async throws -> MapResultCulvertProfileSnapshot
}

/// Reads stored culvert arrays from the exact selected Result HDF through the
/// same resolver used by Result maps. Local bytes are checked both before and
/// after the Host call, so a replaced output can never animate stale barrels.
@MainActor
final class BackendMapResultCulvertProfileProvider: StoredCulvertProfileProvider {
    private let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func load(capture: StoredCulvertProfileCapture,
              profileIndex: Int) async throws -> MapResultCulvertProfileSnapshot {
        guard profileIndex >= 0 else { throw StoredCulvertProfileError.invalidReply }
        let sourceURL = URL(fileURLWithPath: capture.resultOwner.selectedResultPath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw StoredCulvertProfileError.sourceChanged
        }
        let before = try await Self.sha256(at: sourceURL)
        guard before.caseInsensitiveCompare(capture.resultOwner.selectedResultRevision) == .orderedSame else {
            throw StoredCulvertProfileError.sourceChanged
        }

        let request = MapResultCulvertProfileRequest(capture: capture, profileIndex: profileIndex)
        let snapshot: MapResultCulvertProfileSnapshot = try await client.request(
            "map.result.culvertProfile", parameters: request, as: MapResultCulvertProfileSnapshot.self)
        try Self.validate(snapshot, capture: capture, profileIndex: profileIndex)

        guard !Task.isCancelled else { throw CancellationError() }
        let after = try await Self.sha256(at: sourceURL)
        guard after.caseInsensitiveCompare(before) == .orderedSame,
              after.caseInsensitiveCompare(capture.resultOwner.selectedResultRevision) == .orderedSame else {
            throw StoredCulvertProfileError.sourceChanged
        }
        return snapshot
    }

    static func validate(_ snapshot: MapResultCulvertProfileSnapshot,
                         capture: StoredCulvertProfileCapture,
                         profileIndex: Int) throws {
        let owner = capture.resultOwner
        let map = capture.map
        guard profileIndex >= 0,
              snapshot.mapID == map.mapID,
              snapshot.mapIndex == map.mapIndex,
              snapshot.mapName == map.mapName,
              snapshot.mapType == map.mapType,
              canonical(snapshot.projectCanonicalPath) == canonical(map.projectPath),
              snapshot.projectRevision == capture.projectRevision,
              snapshot.projectXmlSHA.caseInsensitiveCompare(map.projectXmlSHA) == .orderedSame,
              snapshot.visualizationRevision.caseInsensitiveCompare(map.expectedVisualizationRevision) == .orderedSame,
              snapshot.contextToken == owner.contextToken,
              snapshot.resultNode == owner.resultNode,
              snapshot.selectionIndex == 0,
              snapshot.selectionMode == capture.selectionMode.rawValue,
              canonical(snapshot.selectedResultPath) == owner.selectedResultPath,
              snapshot.selectedResultRevision.caseInsensitiveCompare(owner.selectedResultRevision) == .orderedSame,
              snapshot.selectedMapType == capture.selectedMapType,
              snapshot.profileIndex == profileIndex,
              snapshot.profileCount >= 0,
              snapshot.profileNames.count == snapshot.profileCount,
              (snapshot.profileCount == 0
                ? (!snapshot.outputAvailable && profileIndex == 0)
                : profileIndex < snapshot.profileCount),
              canonical(snapshot.geometryPath) == owner.selectedResultPath,
              snapshot.geometryRevision.caseInsensitiveCompare(owner.selectedResultRevision) == .orderedSame,
              let geometryName = snapshot.geometryName,
              let geometryOwner = snapshot.geometryOwnerNode,
              geometryOwner.nodeType == "Geometry",
              geometryOwner.rootName == owner.resultNode.rootName,
              geometryOwner.nodeName == geometryName,
              geometryOwner.assetID.map(canonical) == owner.selectedResultPath,
              geometryOwner.parentResultNodeType == owner.resultNode.nodeType,
              geometryOwner.parentResultNodePath == owner.resultNode.nodePath,
              geometryOwner.parentResultNodeName == owner.resultNode.nodeName,
              geometryOwner.parentResultAssetID.map(canonical) == owner.selectedResultPath,
              geometryOwner.parentResultRevision?.caseInsensitiveCompare(owner.selectedResultRevision) == .orderedSame,
              validImmediateChildPath(geometryOwner.nodePath, parentPath: owner.resultNode.nodePath),
              snapshot.barrels.enumerated().allSatisfy({ index, barrel in
                  barrel.sourceOrdinal == index
                      && barrel.id == "barrel:source:\(index)"
                      && barrel.coordinates.count >= 2
                      && barrel.coordinates.allSatisfy { $0.x.isFinite && $0.y.isFinite }
              }),
              Set(snapshot.barrels.map(\.id)).count == snapshot.barrels.count else {
            throw StoredCulvertProfileError.mismatchedReply
        }

        guard snapshot.geometryAvailable || snapshot.barrels.isEmpty else {
            throw StoredCulvertProfileError.invalidReply
        }
        if snapshot.outputAvailable {
            guard snapshot.flow.count > 0,
                  snapshot.outsideDepth.count == snapshot.flow.count * 2,
                  snapshot.outletVelocity.count == snapshot.flow.count,
                  !snapshot.geometryAvailable || snapshot.flow.count == snapshot.barrels.count,
                  snapshot.flow.allSatisfy(\.isFinite),
                  snapshot.outsideDepth.allSatisfy(\.isFinite),
                  snapshot.outletVelocity.allSatisfy(\.isFinite) else {
                throw StoredCulvertProfileError.invalidReply
            }
        } else if !snapshot.flow.isEmpty || !snapshot.outsideDepth.isEmpty || !snapshot.outletVelocity.isEmpty {
            throw StoredCulvertProfileError.invalidReply
        }
        if !snapshot.geometryAvailable || !snapshot.outputAvailable,
           snapshot.diagnostic?.isEmpty != false {
            throw StoredCulvertProfileError.invalidReply
        }
    }

    private static func validImmediateChildPath(_ path: [Int]?, parentPath: [Int]?) -> Bool {
        guard let path, let parentPath, !path.isEmpty, !parentPath.isEmpty,
              path.count == parentPath.count + 1 else { return false }
        return Array(path.prefix(parentPath.count)) == parentPath
    }

    private static func canonical(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }

    private static func sha256(at url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02X", $0) }.joined()
        }.value
    }
}
