import CryptoKit
import Foundation
import RASWorkspaceCore

@MainActor
protocol MapTreeMeshErrorProviding {
    func load(_ context: MapTreeMeshErrorContext) async throws -> MapTreeMeshErrorSnapshot
    func set(_ context: MapTreeMeshErrorContext, checkMeshErrors: Bool?,
             maxFacesPerNodeEntry: Double?) async throws
        -> (MapTreeMeshErrorContext, MapTreeMeshErrorSnapshot)
}

@MainActor
final class BackendMapTreeMeshErrorProvider: MapTreeMeshErrorProviding {
    typealias CurrentCheck = @MainActor (MapTreeMeshErrorContext) -> Bool
    typealias BeginMutation = @MainActor (MapTreeMeshErrorContext) -> Bool
    typealias EndMutation = @MainActor () -> Void
    typealias CurrentMap = @MainActor (UUID) -> MapTreeMapIdentity?
    typealias CurrentLease = @MainActor () -> MapResultComputeReadLease?
    typealias AcceptMapChange = @MainActor (String?, String) throws -> Void

    private let client: BackendProcessClient
    private let isCurrent: CurrentCheck
    private let currentMap: CurrentMap
    private let currentLease: CurrentLease
    private let beginMutation: BeginMutation
    private let endMutation: EndMutation
    private let acceptMapChange: AcceptMapChange

    init(client: BackendProcessClient? = nil,
         isCurrent: @escaping CurrentCheck,
         currentMap: @escaping CurrentMap,
         currentLease: @escaping CurrentLease,
         beginMutation: @escaping BeginMutation,
         endMutation: @escaping EndMutation,
         acceptMapChange: @escaping AcceptMapChange) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
        self.isCurrent = isCurrent
        self.currentMap = currentMap
        self.currentLease = currentLease
        self.beginMutation = beginMutation
        self.endMutation = endMutation
        self.acceptMapChange = acceptMapChange
    }

    func load(_ context: MapTreeMeshErrorContext) async throws -> MapTreeMeshErrorSnapshot {
        try requireCurrent(context)
        let lease = currentLease()
        let draftContext = context.geometryMeshDraftIdentity != nil
        let request = makeRequest(context, action: draftContext ? "draftSettings" : "load",
            lease: lease, readSettingsOnly: draftContext)
        let snapshot: MapTreeMeshErrorSnapshot = try await client.request(
            "map.tree.meshErrors", parameters: request, as: MapTreeMeshErrorSnapshot.self)
        try requireCurrent(context)
        try validate(snapshot, context: context, expectedVisualizationRevision:
            context.map.expectedVisualizationRevision)
        if !draftContext && !isProtected(context.sourcePath, by: lease) {
            try await verifySourceRevision(context)
        } else if !draftContext && snapshot.status != "writerProtected" {
            throw MapTreeMeshErrorError.mismatchedReply
        }
        return snapshot
    }

    func set(_ context: MapTreeMeshErrorContext, checkMeshErrors: Bool?,
             maxFacesPerNodeEntry: Double?) async throws
        -> (MapTreeMeshErrorContext, MapTreeMeshErrorSnapshot) {
        try requireCurrent(context)
        guard currentLease() == nil else { throw MapTreeMeshErrorError.mutationUnavailable }
        guard beginMutation(context) else { throw MapTreeMeshErrorError.mutationUnavailable }
        defer { endMutation() }

        try requireCurrent(context)
        guard currentLease() == nil else { throw MapTreeMeshErrorError.mutationUnavailable }
        try await verifySourceRevision(context)
        let request = makeRequest(context, action: "set", lease: nil,
            readSettingsOnly: context.geometryMeshDraftIdentity != nil,
            checkMeshErrors: checkMeshErrors, maxFacesPerNodeEntry: maxFacesPerNodeEntry)
        let receipt: MapTreeMeshErrorSnapshot = try await client.request(
            "map.tree.meshErrors", parameters: request, as: MapTreeMeshErrorSnapshot.self)
        let receiptContext = try context.acceptingMutationReceipt(
            flowAreaNode: receipt.flowAreaNode, contextToken: receipt.contextToken)
        try validate(receipt, context: receiptContext, expectedVisualizationRevision: nil)
        guard let previous = receipt.previousVisualizationRevision,
              previous.caseInsensitiveCompare(receiptContext.map.expectedVisualizationRevision) == .orderedSame,
              Self.isSHA256(receipt.visualizationRevision),
              receipt.sourceRevision.caseInsensitiveCompare(receiptContext.sourceRevision) == .orderedSame else {
            throw MapTreeMeshErrorError.mismatchedReply
        }

        // The Host has already committed .vis. Accept that exact revision
        // before asking the live map session for its refreshed owner identity.
        try acceptMapChange(previous, receipt.visualizationRevision)
        guard let refreshedMap = currentMap(receiptContext.mapID),
              Self.sameMapOwner(refreshedMap, receiptContext.map),
              refreshedMap.expectedVisualizationRevision.caseInsensitiveCompare(
                receipt.visualizationRevision) == .orderedSame else {
            throw MapTreeMeshErrorError.staleContext
        }
        let refreshedContext = try receiptContext.replacingMap(refreshedMap)
        try validate(receipt, context: refreshedContext,
            expectedVisualizationRevision: receipt.visualizationRevision)
        return (refreshedContext, receipt)
    }

    private func makeRequest(_ context: MapTreeMeshErrorContext, action: String,
                             lease: MapResultComputeReadLease?,
                             readSettingsOnly: Bool = false,
                             checkMeshErrors: Bool? = nil,
                             maxFacesPerNodeEntry: Double? = nil) -> MapTreeMeshErrorRequest {
        MapTreeMeshErrorRequest(
            map: MapTreeMeshErrorMapRequest(map: context.map,
                resultOwner: context.resultOwner, computeReadLease: lease),
            flowAreaNode: context.flowAreaNode,
            projectSessionID: context.projectSessionID.uuidString,
            mapWorkflowIdentity: context.mapWorkflowIdentity,
            contextToken: context.contextToken,
            sourcePath: context.sourcePath,
            sourceRevision: context.sourceRevision,
            resultOwner: context.resultOwner,
            action: action,
            readSettingsOnly: readSettingsOnly,
            checkMeshErrors: checkMeshErrors,
            maxFacesPerNodeEntry: maxFacesPerNodeEntry)
    }

    private func requireCurrent(_ context: MapTreeMeshErrorContext) throws {
        if Task.isCancelled { throw CancellationError() }
        guard isCurrent(context) else { throw MapTreeMeshErrorError.staleContext }
    }

    private func validate(_ snapshot: MapTreeMeshErrorSnapshot,
                          context: MapTreeMeshErrorContext,
                          expectedVisualizationRevision: String?) throws {
        let map = context.map
        guard snapshot.projectSessionID.caseInsensitiveCompare(context.projectSessionID.uuidString) == .orderedSame,
              snapshot.mapWorkflowIdentity == context.mapWorkflowIdentity,
              snapshot.contextToken == context.contextToken,
              Self.canonicalPath(snapshot.projectCanonicalPath) == Self.canonicalPath(map.projectPath),
              Self.isSHA256(snapshot.projectRevision),
              snapshot.projectXmlSHA.caseInsensitiveCompare(map.projectXmlSHA) == .orderedSame,
              expectedVisualizationRevision == nil || snapshot.visualizationRevision.caseInsensitiveCompare(
                expectedVisualizationRevision!) == .orderedSame,
              snapshot.mapID.caseInsensitiveCompare(map.mapID) == .orderedSame,
              snapshot.mapIndex == map.mapIndex, snapshot.mapName == map.mapName,
              snapshot.mapType == map.mapType,
              snapshot.flowAreaNode == context.flowAreaNode,
              Self.canonicalPath(snapshot.sourcePath) == context.sourcePath,
              snapshot.sourceRevision.caseInsensitiveCompare(context.sourceRevision) == .orderedSame,
              Self.isSHA256(snapshot.visualizationRevision),
              (3...64).contains(snapshot.maxFacesPerNode),
              snapshot.omittedIssueCount >= 0, snapshot.totalIssueCount >= snapshot.issues.count,
              snapshot.issues.count + snapshot.omittedIssueCount == snapshot.totalIssueCount else {
            throw MapTreeMeshErrorError.mismatchedReply
        }
    }

    private func verifySourceRevision(_ context: MapTreeMeshErrorContext) async throws {
        let expectedPath = context.sourcePath
        let expectedRevision = context.sourceRevision
        let actual = try await Task.detached(priority: .utility) { () throws -> String in
            let url = URL(fileURLWithPath: expectedPath)
            let digest = SHA256.hash(data: try Data(contentsOf: url, options: [.mappedIfSafe]))
            return digest.map { String(format: "%02X", $0) }.joined()
        }.value
        guard !Task.isCancelled,
              actual.caseInsensitiveCompare(expectedRevision) == .orderedSame else {
            throw MapTreeMeshErrorError.sourceChanged
        }
    }

    private func isProtected(_ path: String, by lease: MapResultComputeReadLease?) -> Bool {
        lease?.canonicalProtectedSourcePaths.contains(path) == true
    }

    private static func sameMapOwner(_ left: MapTreeMapIdentity, _ right: MapTreeMapIdentity) -> Bool {
        left.mapID.caseInsensitiveCompare(right.mapID) == .orderedSame
            && left.mapIndex == right.mapIndex && left.mapName == right.mapName
            && left.mapType == right.mapType
            && canonicalPath(left.projectPath) == canonicalPath(right.projectPath)
            && left.projectXmlSHA.caseInsensitiveCompare(right.projectXmlSHA) == .orderedSame
    }

    private static func canonicalPath(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}
