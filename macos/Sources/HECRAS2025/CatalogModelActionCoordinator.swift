import Foundation
import RASWorkspaceCore
import SwiftUI

enum CatalogManagedModelKind: String, CaseIterable, Sendable {
    case geometry = "Geometry"
    case plan = "Plan"
    case terrain = "Terrain"
    case boundaryCondition = "BoundaryCondition"
    case classification = "Classification"
    case nValue = "NValue"

    var projectSection: ProjectSection {
        switch self {
        case .geometry: .geometries
        case .plan: .plans
        case .terrain: .terrains
        case .boundaryCondition: .boundaryConditions
        case .classification, .nValue: .surfaceLayers
        }
    }

    static func sourceKind(for sourceClass: String) -> Self? {
        switch sourceClass {
        case "GeometryNode", "GeometryNodeVM", "ObservableGeometry": .geometry
        case "PlanNode", "PlanNodeVM", "ObservablePlan": .plan
        case "TerrainNode", "TerrainNodeVM", "ObservableTerrain": .terrain
        case "BoundaryConditionNode", "BoundaryConditionNodeVM", "ObservableBoundaryCondition": .boundaryCondition
        case "ClassificationNode", "ClassificationNodeVM", "ObservableClassificationLayer": .classification
        case "NValueNode", "NValueNodeVM", "ObservableNValueLayer": .nValue
        default: nil
        }
    }

    static func catalogGroup(_ group: CatalogGroup) -> Self? {
        switch group {
        case .geometries: .geometry
        case .plans: .plan
        case .terrains: .terrain
        case .boundaryConditions: .boundaryCondition
        case .classifications: .classification
        case .nValues: .nValue
        case .results, .surfaceLayers: nil
        }
    }
}

struct CatalogModelActionTarget: Equatable, Sendable {
    let asset: ProjectAsset
    let kind: CatalogManagedModelKind

    static func resolve(node: LayerTreeNode, assets: [ProjectAsset]) -> Self? {
        guard let kind = CatalogManagedModelKind.sourceKind(for: node.sourceClass),
              let assetID = node.assetID,
              let asset = asset(withNodeID: assetID, in: assets),
              asset.section == kind.projectSection else { return nil }
        return Self(asset: asset, kind: kind)
    }

    static func resolve(asset: ProjectAsset, group: CatalogGroup) -> Self? {
        guard let kind = CatalogManagedModelKind.catalogGroup(group),
              asset.section == kind.projectSection else { return nil }
        return Self(asset: asset, kind: kind)
    }

    static func asset(withNodeID nodeID: String, in assets: [ProjectAsset]) -> ProjectAsset? {
        if let exact = assets.first(where: { $0.id == nodeID }) { return exact }
        guard nodeID.hasPrefix("/"),
              let canonicalNodePath = Self.canonicalPath(nodeID) else { return nil }
        return assets.first { Self.canonicalPath($0.url.path) == canonicalNodePath }
    }

    static func canonicalPath(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        return SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }
}

enum CatalogModelActionIntent: String, Sendable {
    case rename
    case duplicate
    case clone
    case delete
}

enum CatalogModelActionCaller: String, Sendable {
    case inspector
    case catalog
    case projectTree
}

/// The action keeps its originating identity and project snapshot so a sheet
/// opened after a tree refresh cannot silently adopt a newer project revision.
struct CatalogModelActionPresentation: Identifiable, Equatable, Sendable {
    let id: UUID
    let assetID: String
    let kind: String
    let action: String
    let caller: String
    let projectSessionID: UUID
    let assetsRevision: Int
    let projectPath: String?
    let canonicalProjectPath: String?
    let projectXMLFingerprint: String?
    let assetPath: String
    let canonicalAssetPath: String
    /// Optional source revision captured by a typed diagnostic target. When
    /// present, action inspection and execution must still match that exact
    /// source file revision rather than merely the current same-path asset.
    let expectedAssetRevision: String?

    var intent: CatalogModelActionIntent? { CatalogModelActionIntent(rawValue: action) }
    var actionCaller: CatalogModelActionCaller? { CatalogModelActionCaller(rawValue: caller) }

    @MainActor
    init(asset: ProjectAsset, kind: CatalogManagedModelKind, intent: CatalogModelActionIntent,
         caller: CatalogModelActionCaller, store: WorkspaceStore,
         expectedAssetRevision: String? = nil) {
        let projectURL = store.document?.url
        self.id = UUID()
        self.assetID = asset.id
        self.kind = kind.rawValue
        self.action = intent.rawValue
        self.caller = caller.rawValue
        self.projectSessionID = store.projectSessionID
        self.assetsRevision = store.assetsRevision
        self.projectPath = projectURL?.path
        self.canonicalProjectPath = projectURL.flatMap { CatalogModelActionTarget.canonicalPath($0.path) }
        self.projectXMLFingerprint = store.document.map { CatalogModelActionDigest.textFingerprint($0.editorXML) }
        self.assetPath = asset.url.path
        self.canonicalAssetPath = CatalogModelActionTarget.canonicalPath(asset.url.path) ?? asset.url.path
        self.expectedAssetRevision = expectedAssetRevision
    }

    @MainActor
    static func make(asset: ProjectAsset, kind: CatalogManagedModelKind,
                     intent: CatalogModelActionIntent, caller: CatalogModelActionCaller,
                     store: WorkspaceStore,
                     expectedAssetRevision: String? = nil) -> Self? {
        guard let current = store.assets.first(where: { $0.id == asset.id }), current == asset,
              asset.section == kind.projectSection else { return nil }
        return Self(asset: asset, kind: kind, intent: intent, caller: caller, store: store,
            expectedAssetRevision: expectedAssetRevision)
    }
}

/// A value token for the exact request inputs accepted before an async inspect.
/// Equality is checked after every network/process await and again at confirm.
struct CatalogModelActionContextStamp: Equatable, Sendable {
    let presentationID: UUID
    let assetID: String
    let kind: String
    let action: String
    let caller: String
    let projectSessionID: UUID
    let assetsRevision: Int
    let projectPath: String
    let canonicalProjectPath: String
    let projectXMLFingerprint: String
    let assetPath: String
    let canonicalAssetPath: String
    let expectedAssetRevision: String?

    func stillOwns(_ current: Self?) -> Bool { current == self }

    @MainActor
    static func capture(_ presentation: CatalogModelActionPresentation,
                        store: WorkspaceStore) -> Self? {
        guard store.catalogModelActionPresentation?.id == presentation.id,
              presentation.projectSessionID == store.projectSessionID,
              presentation.assetsRevision == store.assetsRevision,
              let intent = presentation.intent,
              let caller = presentation.actionCaller,
              let kind = CatalogManagedModelKind(rawValue: presentation.kind),
              let project = store.document,
              let projectURL = project.url,
              let currentProjectPath = CatalogModelActionTarget.canonicalPath(projectURL.path),
              let asset = store.assets.first(where: { $0.id == presentation.assetID }),
              asset.section == kind.projectSection,
              let currentAssetPath = CatalogModelActionTarget.canonicalPath(asset.url.path),
              let expectedProjectPath = presentation.canonicalProjectPath,
              let expectedXMLFingerprint = presentation.projectXMLFingerprint else { return nil }
        let currentXMLFingerprint = CatalogModelActionDigest.textFingerprint(project.editorXML)
        guard presentation.projectPath == projectURL.path,
              currentProjectPath == expectedProjectPath,
              currentXMLFingerprint == expectedXMLFingerprint,
              presentation.assetPath == asset.url.path,
              currentAssetPath == presentation.canonicalAssetPath else { return nil }
        return Self(presentationID: presentation.id, assetID: asset.id, kind: kind.rawValue,
            action: intent.rawValue, caller: caller.rawValue,
            projectSessionID: presentation.projectSessionID, assetsRevision: presentation.assetsRevision,
            projectPath: projectURL.path, canonicalProjectPath: currentProjectPath,
            projectXMLFingerprint: currentXMLFingerprint, assetPath: asset.url.path,
            canonicalAssetPath: currentAssetPath,
            expectedAssetRevision: presentation.expectedAssetRevision)
    }
}

enum CatalogModelActionExecutionRoute {
    static func action(for intent: CatalogModelActionIntent, caller: CatalogModelActionCaller,
                       kind: CatalogManagedModelKind,
                       availableActions: Set<String>?) -> String? {
        guard let availableActions else { return nil }
        let candidate: String
        switch intent {
        case .rename: candidate = "rename"
        case .delete: candidate = "delete"
        case .clone: candidate = "clone"
        case .duplicate:
            if caller == .inspector { candidate = "clone" }
            else { candidate = "duplicate" }
        }
        return availableActions.contains(candidate) ? candidate : nil
    }
}

@MainActor
final class CatalogModelActionCoordinator: ObservableObject {
    @Published private(set) var inspection: CatalogModelActionInspection?
    @Published private(set) var isLoading = false
    @Published private(set) var isPerforming = false
    @Published private(set) var error: String?

    private let store: WorkspaceStore
    private let session: CatalogModelActionSession
    private var presentationID: UUID?
    private var contextStamp: CatalogModelActionContextStamp?
    private var assetSnapshot: ProjectAsset?
    private var projectURLSnapshot: URL?
    private var projectXMLSnapshot: String?

    init(store: WorkspaceStore) {
        self.store = store
        let provider = (store.modelProvider as? BackendModelProvider).map {
            BackendCatalogModelActionProvider(client: $0.client)
        }
        self.session = CatalogModelActionSession(provider: provider)
    }

    var deleteConfirmationText: String {
        guard let inspection else { return L10n.text("Refresh the model before deleting it.") }
        var lines = [L10n.text("Files moved to Trash")]
        lines += inspection.trashPaths.map(\.path)
        if !inspection.deleteDependencies.isEmpty {
            lines.append(L10n.text("Related project items") + ":")
            lines += inspection.deleteDependencies.map { dependency in
                if let path = dependency.assetPath { "\(dependency.kind): \(dependency.name) — \(path)" }
                else { "\(dependency.kind): \(dependency.name)" }
            }
        }
        return lines.joined(separator: "\n")
    }

    func inspect(_ presentation: CatalogModelActionPresentation) async {
        session.invalidate()
        inspection = nil
        error = nil
        isLoading = true
        presentationID = presentation.id
        contextStamp = nil
        assetSnapshot = nil
        projectURLSnapshot = nil
        projectXMLSnapshot = nil
        defer { if presentationID == presentation.id { isLoading = false } }

        guard let stamp = CatalogModelActionContextStamp.capture(presentation, store: store),
              let asset = store.assets.first(where: { $0.id == stamp.assetID }),
              let project = store.document,
              let projectURL = project.url else {
            error = L10n.text("The selected model changed. Refresh and try again.")
            return
        }
        let projectXML = project.editorXML
        contextStamp = stamp
        assetSnapshot = asset
        projectURLSnapshot = projectURL
        projectXMLSnapshot = projectXML
        await session.inspect(asset: asset, kind: stamp.kind, projectPath: projectURL,
            projectXML: projectXML, projectSessionID: stamp.projectSessionID,
            assetsRevision: stamp.assetsRevision)
        guard isCurrent(presentation) else {
            session.invalidate()
            inspection = nil
            error = L10n.text("The selected model changed. Refresh and try again.")
            return
        }
        if let expected = presentation.expectedAssetRevision,
           session.inspection?.revision.caseInsensitiveCompare(expected) != .orderedSame {
            session.invalidate()
            inspection = nil
            error = L10n.text("The diagnostic source file changed. Refresh the diagnostic and try again.")
            return
        }
        inspection = session.inspection
        error = session.error
        if inspection != nil, error == nil,
           !isRequestedActionAvailable(presentation) {
            error = L10n.text("This action is unavailable for the selected model.")
        }
    }

    func isRequestedActionAvailable(_ presentation: CatalogModelActionPresentation) -> Bool {
        guard presentationID == presentation.id,
              let stamp = contextStamp,
              stamp.presentationID == presentation.id,
              isCurrent(presentation),
              let intent = presentation.intent,
              let caller = presentation.actionCaller,
              let kind = CatalogManagedModelKind(rawValue: presentation.kind),
              let inspection,
              inspection.kind == kind.rawValue,
              presentation.expectedAssetRevision.map({
                  inspection.revision.caseInsensitiveCompare($0) == .orderedSame
              }) ?? true else { return false }
        return CatalogModelActionExecutionRoute.action(for: intent, caller: caller, kind: kind,
            availableActions: Set(inspection.availableActions)) != nil
    }

    func perform(_ presentation: CatalogModelActionPresentation, name: String? = nil) async -> Bool {
        guard isRequestedActionAvailable(presentation),
              let stamp = contextStamp,
              let intent = presentation.intent,
              let caller = presentation.actionCaller,
              let kind = CatalogManagedModelKind(rawValue: presentation.kind),
              let inspection,
              let action = CatalogModelActionExecutionRoute.action(for: intent, caller: caller,
                    kind: kind, availableActions: Set(inspection.availableActions)),
              let asset = assetSnapshot, asset.id == stamp.assetID,
              let projectURL = projectURLSnapshot,
              let projectXML = projectXMLSnapshot else {
            error = L10n.text("The selected model changed. Refresh and try again.")
            return false
        }
        guard store.beginCatalogModelAction(assetID: stamp.assetID,
                projectSessionID: stamp.projectSessionID) else {
            error = store.errorMessage ?? L10n.text("Another project operation is in progress.")
            return false
        }
        defer { store.endCatalogModelAction(projectSessionID: stamp.projectSessionID) }

        isPerforming = true
        error = nil
        defer { isPerforming = false }
        var receipt: CatalogModelActionReceipt?
        do {
            let prepared = try await session.perform(asset: asset, kind: kind.rawValue,
                projectPath: projectURL, projectXML: projectXML,
                projectSessionID: stamp.projectSessionID, assetsRevision: stamp.assetsRevision,
                action: action, name: name)
            receipt = prepared
            guard isCurrent(presentation),
                  store.document?.editorXML == projectXML,
                  store.assets.first(where: { $0.id == stamp.assetID }) == asset,
                  prepared.action == action,
                  prepared.kind == kind.rawValue,
                  prepared.originalAssetPath == asset.url.path,
                  prepared.canonicalOriginalAssetPath == stamp.canonicalAssetPath,
                  prepared.originalSHA == inspection.revision,
                  prepared.projectXmlFingerprint == stamp.projectXMLFingerprint else {
                throw CatalogModelActionPresentationError.changed
            }
            try store.applyCatalogModelAction(prepared, assetID: stamp.assetID,
                projectSessionID: stamp.projectSessionID)
            await session.cleanup(prepared)
            receipt = nil
            if store.catalogModelActionPresentation?.id == presentation.id {
                store.catalogModelActionPresentation = nil
            }
            session.invalidate()
            return true
        } catch {
            if let receipt { await session.cleanup(receipt) }
            self.error = L10n.text(error.localizedDescription)
            return false
        }
    }

    func invalidate(_ expectedPresentationID: UUID) {
        guard presentationID == expectedPresentationID, !isPerforming else { return }
        session.invalidate()
        presentationID = nil
        contextStamp = nil
        assetSnapshot = nil
        projectURLSnapshot = nil
        projectXMLSnapshot = nil
        inspection = nil
    }

    private func isCurrent(_ presentation: CatalogModelActionPresentation) -> Bool {
        guard presentationID == presentation.id,
              let captured = contextStamp,
              let current = CatalogModelActionContextStamp.capture(presentation, store: store) else { return false }
        return captured.stillOwns(current)
    }
}

private enum CatalogModelActionPresentationError: LocalizedError {
    case changed
    var errorDescription: String? { "The selected model changed. Refresh and try again." }
}
