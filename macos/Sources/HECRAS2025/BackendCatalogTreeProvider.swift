import Foundation
import CryptoKit
import RASWorkspaceCore

/// Decoded catalog snapshot wire values are kept visible to the editing test
/// target so optional diagnostic fields can be checked against older payloads.
struct CatalogTreeSnapshotResponse: Decodable, Sendable {
    let roots: [CatalogTreeNodeResponse]
}

struct CatalogTreeNodeResponse: Decodable, Sendable {
    let id: String
    let sourceClass: String
    let name: String
    var localizeName = false
    var children: [CatalogTreeNodeResponse]? = nil
    var assetID: String? = nil
    var catalogSummary: CatalogTreeSummaryResponse? = nil
    var backupSummary: CatalogTreeBackupSummaryResponse? = nil
    var properties: [CatalogTreePropertyResponse]? = nil
    var checked: String? = nil
    var isPinned = false
    var canPin = false
    var canRename = false
    var canMove = false
    var canAcceptChildren = false
    var canCreateFolder = false
    var layerErrors: [CatalogLayerDiagnostic]? = nil
    var diagnosticStatus: String? = nil
    var diagnosticReadError: String? = nil
    var diagnosticSourceIdentity: String? = nil
    var diagnosticSourceRevision: String? = nil
    var resultComputeState: String? = nil
    var resultComputeFailureReason: String? = nil
    var resultComputeSourcePath: String? = nil
    var resultComputeSourceRevision: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id, sourceClass, name, localizeName, children, assetID, catalogSummary
        case backupSummary, properties, checked, isPinned, canPin, canRename, canMove
        case canAcceptChildren, canCreateFolder, layerErrors, diagnosticStatus
        case diagnosticReadError, diagnosticSourceIdentity, diagnosticSourceRevision
        case resultComputeState, resultComputeFailureReason, resultComputeSourcePath, resultComputeSourceRevision
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        sourceClass = try values.decode(String.self, forKey: .sourceClass)
        name = try values.decode(String.self, forKey: .name)
        localizeName = try values.decodeIfPresent(Bool.self, forKey: .localizeName) ?? false
        children = try values.decodeIfPresent([CatalogTreeNodeResponse].self, forKey: .children)
        assetID = try values.decodeIfPresent(String.self, forKey: .assetID)
        catalogSummary = try values.decodeIfPresent(CatalogTreeSummaryResponse.self, forKey: .catalogSummary)
        backupSummary = try values.decodeIfPresent(CatalogTreeBackupSummaryResponse.self, forKey: .backupSummary)
        properties = try values.decodeIfPresent([CatalogTreePropertyResponse].self, forKey: .properties)
        checked = try values.decodeIfPresent(String.self, forKey: .checked)
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        canPin = try values.decodeIfPresent(Bool.self, forKey: .canPin) ?? false
        canRename = try values.decodeIfPresent(Bool.self, forKey: .canRename) ?? false
        canMove = try values.decodeIfPresent(Bool.self, forKey: .canMove) ?? false
        canAcceptChildren = try values.decodeIfPresent(Bool.self, forKey: .canAcceptChildren) ?? false
        canCreateFolder = try values.decodeIfPresent(Bool.self, forKey: .canCreateFolder) ?? false
        layerErrors = try values.decodeIfPresent([CatalogLayerDiagnostic].self, forKey: .layerErrors)
        diagnosticStatus = try values.decodeIfPresent(String.self, forKey: .diagnosticStatus)
        diagnosticReadError = try values.decodeIfPresent(String.self, forKey: .diagnosticReadError)
        diagnosticSourceIdentity = try values.decodeIfPresent(String.self, forKey: .diagnosticSourceIdentity)
        diagnosticSourceRevision = try values.decodeIfPresent(String.self, forKey: .diagnosticSourceRevision)
        resultComputeState = try values.decodeIfPresent(String.self, forKey: .resultComputeState)
        resultComputeFailureReason = try values.decodeIfPresent(String.self, forKey: .resultComputeFailureReason)
        resultComputeSourcePath = try values.decodeIfPresent(String.self, forKey: .resultComputeSourcePath)
        resultComputeSourceRevision = try values.decodeIfPresent(String.self, forKey: .resultComputeSourceRevision)
    }

    var layerTreeNode: LayerTreeNode {
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
            children: children?.map(\.layerTreeNode),
            checked: checkState,
            isPinned: isPinned,
            canPin: canPin,
            canRename: canRename,
            canMove: canMove,
            canAcceptChildren: canAcceptChildren,
            canCreateFolder: canCreateFolder,
            assetID: assetID,
            properties: properties?.map { .init(id: $0.id, label: $0.label, value: $0.value) } ?? [],
            contextMenu: [],
            backupSummary: backupSummary.map {
                .init(filename: $0.filename, dateCreated: $0.dateCreated,
                      dateLastModified: $0.dateLastModified,
                      canSaveAsNewGeometry: $0.canSaveAsNewGeometry,
                      revision: $0.revision, parentGeometryPath: $0.parentGeometryPath,
                      parentGeometryRevision: $0.parentGeometryRevision,
                      projectRevision: $0.projectRevision)
            },
            catalogSummary: catalogSummary.map {
                .init(name: $0.name, filename: $0.filename, dateCreated: $0.dateCreated,
                      dateLastModified: $0.dateLastModified, description: $0.description)
            },
            layerErrors: layerErrors,
            diagnosticStatus: diagnosticStatus,
            diagnosticReadError: diagnosticReadError,
            diagnosticSourceIdentity: diagnosticSourceIdentity,
            diagnosticSourceRevision: diagnosticSourceRevision,
            resultComputeState: resultComputeState,
            resultComputeFailureReason: resultComputeFailureReason,
            resultComputeSourcePath: resultComputeSourcePath,
            resultComputeSourceRevision: resultComputeSourceRevision
        )
    }
}

struct CatalogTreeSummaryResponse: Decodable, Sendable {
    let name: String?
    let filename: String?
    let dateCreated: String?
    let dateLastModified: String?
    let description: String?
}

struct CatalogTreeBackupSummaryResponse: Decodable, Sendable {
    let filename: String
    let dateCreated: String
    let dateLastModified: String
    let canSaveAsNewGeometry: Bool
    let revision: String?
    let parentGeometryPath: String?
    let parentGeometryRevision: String?
    let projectRevision: String?
}

struct CatalogTreePropertyResponse: Decodable, Sendable {
    let id: String
    let label: String
    let value: String
}

/// Source-backed provider for the catalog and model-tree snapshots. The two
/// trees use separate backend operations because RasCatalogTree and
/// ProjectTreeModeVM have different roots and child semantics.
@MainActor
final class BackendCatalogTreeProvider: LayerTreeProvider {
    private let client: BackendProcessClient
    private let projectXML: @MainActor () -> String?
    private let mapDocuments: @MainActor () -> [CatalogMapDocument]
    private let isContextCurrent: @MainActor (LayerTreeContext) -> Bool
    private let beginBackupRestore: @MainActor () -> Bool
    private let endBackupRestore: @MainActor () -> Void
    private var backupCaptures: [LayerTreeContext: [String: BackupRestoreCapture]] = [:]

    init(
        client: BackendProcessClient? = nil,
        projectXML: @escaping @MainActor () -> String? = { nil },
        mapDocuments: @escaping @MainActor () -> [CatalogMapDocument] = { [] },
        isContextCurrent: @escaping @MainActor (LayerTreeContext) -> Bool = { _ in true },
        beginBackupRestore: @escaping @MainActor () -> Bool = { true },
        endBackupRestore: @escaping @MainActor () -> Void = {}
    ) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
        self.projectXML = projectXML
        self.mapDocuments = mapDocuments
        self.isContextCurrent = isContextCurrent
        self.beginBackupRestore = beginBackupRestore
        self.endBackupRestore = endBackupRestore
    }

    func load(_ context: LayerTreeContext) async throws -> LayerTreeSnapshot {
        guard isContextCurrent(context) else { throw CancellationError() }
        guard let projectPath = context.projectURL?.path else {
            throw BackendServiceError(code: "invalidInput", message: "Open a saved project before loading its catalog tree.")
        }
        let currentXML = projectXML()
        let currentMaps = mapDocuments()
        let request = CatalogTreeLoadRequest(
            projectPath: projectPath,
            projectXml: currentXML,
            mode: context.mode,
            focusedGeometryIds: context.focusedGeometryIDs,
            focusedPlanIds: context.focusedPlanIDs,
            mapId: context.mapID.uuidString,
            maps: currentMaps,
            coreLayerContext: context.coreLayerContext
        )
        let method = context.mode == "Catalog" ? "catalog.tree.load" : "project.tree.load"
        let response = try await client.request(method, parameters: request, as: CatalogTreeSnapshotResponse.self)
        guard isContextCurrent(context) else { throw CancellationError() }
        let roots = response.roots.map(\.layerTreeNode)
        if context.mode == "Catalog" {
            backupCaptures[context] = Self.backupCaptures(in: response.roots, projectPath: projectPath,
                projectXML: currentXML, maps: currentMaps)
            if backupCaptures.count > 6, let oldest = backupCaptures.keys.first(where: { $0 != context }) {
                backupCaptures.removeValue(forKey: oldest)
            }
        }
        return .init(roots: roots)
    }

    func perform(_ action: LayerTreeAction, context: LayerTreeContext) async throws -> LayerTreeSnapshot {
        switch action {
        case .select:
            // Selection is presentation state. The native pane uses the node's
            // source asset id to route the real editor/inspector action.
            return try await load(context)
        case .saveBackupAsNewGeometry(let nodeID):
            return try await restoreGeometryBackup(nodeID: nodeID, context: context)
        case .rename, .visibility, .pin, .move, .newFolder, .contextCommand:
            throw BackendServiceError(code: "unsupported", message: "This tree action is not connected to a source operation.")
        }
    }

    private func restoreGeometryBackup(nodeID: String, context: LayerTreeContext) async throws -> LayerTreeSnapshot {
        guard context.mode == "Catalog", isContextCurrent(context),
              let capture = backupCaptures[context]?[nodeID],
              let projectURL = context.projectURL,
              SourceFilePaths.canonical(projectURL) ==
                SourceFilePaths.canonical(URL(fileURLWithPath: capture.projectPath)),
              projectXML() == capture.projectXML,
              mapDocuments() == capture.maps else {
            throw BackendServiceError(code: "sourceChanged", message: "Refresh the Geometry backup before restoring it.")
        }
        guard let projectXML = capture.projectXML,
              let revision = capture.summary.revision,
              let parentPath = capture.summary.parentGeometryPath,
              let parentRevision = capture.summary.parentGeometryRevision,
              let expectedProjectRevision = capture.summary.projectRevision,
              capture.summary.canSaveAsNewGeometry else {
            throw BackendServiceError(code: "unsupported", message: "The selected Geometry backup cannot be restored.")
        }
        guard beginBackupRestore() else {
            throw BackendServiceError(code: "busy", message: L10n.text("Another project operation is in progress."))
        }
        defer { endBackupRestore() }
        let request = GeometryBackupRestoreRequest(
            projectPath: capture.projectPath,
            projectXml: projectXML,
            backupPath: capture.summary.filename,
            backupCanonicalPath: capture.canonicalBackupPath,
            expectedBackupRevision: revision,
            parentGeometryPath: parentPath,
            expectedParentGeometryRevision: parentRevision,
            expectedProjectRevision: expectedProjectRevision,
            coreLayerContext: context.coreLayerContext
        )
        let receipt = try await client.request("geometry.backup.restore", parameters: request,
            as: GeometryBackupRestoreResponse.self)
        guard isContextCurrent(context),
              SourceFilePaths.canonical(URL(fileURLWithPath: receipt.projectPath)) ==
                SourceFilePaths.canonical(projectURL),
              receipt.backupRevision == revision,
              receipt.parentGeometryPath == parentPath,
              receipt.parentGeometryRevision == parentRevision,
              receipt.projectRevision == expectedProjectRevision,
              SourceFilePaths.canonical(URL(fileURLWithPath: receipt.backupPath)) == capture.canonicalBackupPath,
              receipt.newAssetRevision == revision,
              receipt.projectXmlFingerprint == Self.sha256(projectXML),
              URL(fileURLWithPath: receipt.newAssetPath).deletingPathExtension().lastPathComponent == receipt.newName else {
            throw BackendServiceError(code: "protocolFailure", message: "The Geometry restore reply does not match the selected backup.")
        }

        let refreshed = try await load(context)
        guard isContextCurrent(context),
              let newNode = refreshed.roots.lazy.compactMap({ Self.findGeometry($0, assetPath: receipt.newAssetPath) }).first else {
            throw BackendServiceError(code: "protocolFailure", message: "The restored Geometry could not be found in the project catalog.")
        }
        return LayerTreeSnapshot(roots: refreshed.roots, selection: .node(newNode.id),
            operationWarning: receipt.cleanupWarning)
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    private static func backupCaptures(in roots: [CatalogTreeNodeResponse], projectPath: String,
        projectXML: String?, maps: [CatalogMapDocument]) -> [String: BackupRestoreCapture] {
        var captures: [String: BackupRestoreCapture] = [:]
        func visit(_ node: CatalogTreeNodeResponse) {
            if node.sourceClass == "BackupNodeVM", let summary = node.backupSummary,
               let canonicalBackupPath = node.assetID {
                captures[node.id] = BackupRestoreCapture(projectPath: projectPath, projectXML: projectXML,
                    maps: maps, canonicalBackupPath: canonicalBackupPath,
                    summary: BackupCatalogSummaryData(filename: summary.filename,
                        dateCreated: summary.dateCreated, dateLastModified: summary.dateLastModified,
                        canSaveAsNewGeometry: summary.canSaveAsNewGeometry, revision: summary.revision,
                        parentGeometryPath: summary.parentGeometryPath,
                        parentGeometryRevision: summary.parentGeometryRevision,
                        projectRevision: summary.projectRevision))
            }
            for child in node.children ?? [] { visit(child) }
        }
        for root in roots { visit(root) }
        return captures
    }

    private static func findGeometry(_ node: LayerTreeNode, assetPath: String) -> LayerTreeNode? {
        if node.sourceClass == "ObservableGeometry", let candidate = node.assetID,
           SourceFilePaths.canonical(URL(fileURLWithPath: candidate)) ==
            SourceFilePaths.canonical(URL(fileURLWithPath: assetPath)) { return node }
        return node.children?.lazy.compactMap { findGeometry($0, assetPath: assetPath) }.first
    }

    private struct BackupRestoreCapture {
        let projectPath: String
        let projectXML: String?
        let maps: [CatalogMapDocument]
        let canonicalBackupPath: String
        let summary: BackupCatalogSummaryData
    }

    private struct GeometryBackupRestoreRequest: Encodable, Sendable {
        let projectPath: String
        let projectXml: String
        let backupPath: String
        let backupCanonicalPath: String
        let expectedBackupRevision: String
        let parentGeometryPath: String
        let expectedParentGeometryRevision: String
        let expectedProjectRevision: String
        var coreLayerContext: CoreLayerRequestContext? = nil
    }

    private struct GeometryBackupRestoreResponse: Decodable, Sendable {
        let projectPath: String
        let backupPath: String
        let backupRevision: String
        let parentGeometryPath: String
        let parentGeometryRevision: String
        let projectRevision: String
        let newAssetPath: String
        let newName: String
        let newAssetRevision: String
        let projectXmlFingerprint: String
        let cleanupWarning: String?
    }

    private struct CatalogTreeLoadRequest: Encodable, Sendable {
        let projectPath: String
        let projectXml: String?
        let mode: String
        let focusedGeometryIds: [String]
        let focusedPlanIds: [String]
        let mapId: String
        let maps: [CatalogMapDocument]
        var coreLayerContext: CoreLayerRequestContext? = nil
    }

}
